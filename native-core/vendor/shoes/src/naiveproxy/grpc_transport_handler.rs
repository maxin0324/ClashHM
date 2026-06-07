//! Clash/Xray gRPC transport client wrapper.
//!
//! This opens an HTTP/2 gRPC stream at `/{service_name}/Tun` and carries the
//! inner proxy protocol through gRPC data messages.

use std::collections::HashMap;
use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

use async_trait::async_trait;
use bytes::{Buf, Bytes};
use http::{Method, Request, StatusCode, Version};
use log::debug;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::Mutex;

use crate::address::ResolvedLocation;
use crate::async_stream::{AsyncMessageStream, AsyncPing, AsyncStream};
use crate::tcp::tcp_handler::{TcpClientHandler, TcpClientSetupResult};

use super::h2_multi_stream::H2MultiStream;

#[derive(Clone)]
struct GrpcTransportSession {
    send_request: h2::client::SendRequest<Bytes>,
    driver_handle: Arc<DriverHandle>,
}

struct DriverHandle(tokio::task::AbortHandle);

impl Drop for DriverHandle {
    fn drop(&mut self) {
        debug!("gRPC transport: all session clones dropped, aborting connection driver");
        self.0.abort();
    }
}

impl GrpcTransportSession {
    async fn new(stream: Box<dyn AsyncStream>) -> io::Result<Self> {
        const WINDOW_SIZE: u32 = 256 * 1024;
        const MAX_FRAME_SIZE: u32 = (1 << 24) - 1;

        let (send_request, connection) = h2::client::Builder::new()
            .initial_window_size(WINDOW_SIZE)
            .initial_connection_window_size(WINDOW_SIZE)
            .max_frame_size(MAX_FRAME_SIZE)
            .max_concurrent_streams(1024)
            .handshake(stream)
            .await
            .map_err(|e| io::Error::other(format!("gRPC transport handshake failed: {e}")))?;

        let abort_handle = tokio::spawn(async move {
            if let Err(e) = connection.await {
                debug!("gRPC transport connection ended: {e}");
            }
        })
        .abort_handle();

        Ok(Self {
            send_request,
            driver_handle: Arc::new(DriverHandle(abort_handle)),
        })
    }

    fn is_ready(&self) -> bool {
        true
    }

    async fn open_stream(
        &mut self,
        path: &str,
        authority: &Option<String>,
        headers: &Option<HashMap<String, String>>,
    ) -> io::Result<Box<dyn AsyncStream>> {
        let mut request = Request::builder()
            .method(Method::POST)
            .uri(path)
            .version(Version::HTTP_2)
            .header("content-type", "application/grpc")
            .header("te", "trailers");

        if let Some(authority) = authority {
            request = request.header("host", authority);
        }
        if let Some(headers) = headers {
            for (key, value) in headers {
                request = request.header(key.as_str(), value.as_str());
            }
        }

        let request = request
            .body(())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

        let (response_future, send_stream) = self
            .send_request
            .send_request(request, false)
            .map_err(|e| io::Error::other(format!("failed to send gRPC request: {e}")))?;

        let response = response_future
            .await
            .map_err(|e| io::Error::other(format!("gRPC response error: {e}")))?;

        if response.status() != StatusCode::OK {
            return Err(io::Error::other(format!(
                "gRPC request failed with status: {}",
                response.status()
            )));
        }

        let h2_stream = H2MultiStream::new(send_stream, response.into_body());
        Ok(Box::new(GrpcDataStream::new(h2_stream)))
    }
}

pub struct GrpcTransportTcpClientHandler {
    path: String,
    authority: Option<String>,
    headers: Option<HashMap<String, String>>,
    handler: Box<dyn TcpClientHandler>,
    session: Arc<Mutex<Option<GrpcTransportSession>>>,
}

impl std::fmt::Debug for GrpcTransportTcpClientHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GrpcTransportTcpClientHandler")
            .field("path", &self.path)
            .field("authority", &self.authority)
            .finish()
    }
}

impl GrpcTransportTcpClientHandler {
    pub fn new(
        service_name: Option<String>,
        authority: Option<String>,
        headers: Option<HashMap<String, String>>,
        handler: Box<dyn TcpClientHandler>,
    ) -> Self {
        Self {
            path: grpc_path(service_name),
            authority,
            headers,
            handler,
            session: Arc::new(Mutex::new(None)),
        }
    }

    async fn setup_transport_stream(
        &self,
        client_stream: Box<dyn AsyncStream>,
    ) -> io::Result<Box<dyn AsyncStream>> {
        let mut session = self.get_or_create_session(client_stream).await?;
        session
            .open_stream(&self.path, &self.authority, &self.headers)
            .await
    }

    async fn get_or_create_session(
        &self,
        client_stream: Box<dyn AsyncStream>,
    ) -> io::Result<GrpcTransportSession> {
        let mut guard = self.session.lock().await;
        if let Some(ref session) = *guard {
            if session.is_ready() {
                return Ok(session.clone());
            }
        }

        let session = GrpcTransportSession::new(client_stream).await?;
        *guard = Some(session.clone());
        Ok(session)
    }
}

#[async_trait]
impl TcpClientHandler for GrpcTransportTcpClientHandler {
    async fn setup_client_tcp_stream(
        &self,
        client_stream: Box<dyn AsyncStream>,
        remote_location: ResolvedLocation,
    ) -> io::Result<TcpClientSetupResult> {
        let grpc_stream = self.setup_transport_stream(client_stream).await?;
        self.handler
            .setup_client_tcp_stream(grpc_stream, remote_location)
            .await
    }

    fn supports_udp_over_tcp(&self) -> bool {
        self.handler.supports_udp_over_tcp()
    }

    async fn setup_client_udp_bidirectional(
        &self,
        client_stream: Box<dyn AsyncStream>,
        target: ResolvedLocation,
    ) -> io::Result<Box<dyn AsyncMessageStream>> {
        let grpc_stream = self.setup_transport_stream(client_stream).await?;
        self.handler
            .setup_client_udp_bidirectional(grpc_stream, target)
            .await
    }
}

struct GrpcDataStream<S> {
    inner: S,
    encoded_read_buf: Vec<u8>,
    decoded_read_buf: Bytes,
    write_buf: Vec<u8>,
    write_offset: usize,
    pending_user_len: usize,
}

impl<S> GrpcDataStream<S> {
    fn new(inner: S) -> Self {
        Self {
            inner,
            encoded_read_buf: Vec::new(),
            decoded_read_buf: Bytes::new(),
            write_buf: Vec::new(),
            write_offset: 0,
            pending_user_len: 0,
        }
    }

    fn clear_pending_write(&mut self) {
        self.write_buf.clear();
        self.write_offset = 0;
        self.pending_user_len = 0;
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for GrpcDataStream<S> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if !self.decoded_read_buf.is_empty() {
            let to_copy = self.decoded_read_buf.len().min(buf.remaining());
            buf.put_slice(&self.decoded_read_buf[..to_copy]);
            self.decoded_read_buf.advance(to_copy);
            return Poll::Ready(Ok(()));
        }

        loop {
            if self.encoded_read_buf.len() >= 5 {
                if self.encoded_read_buf[0] != 0 {
                    return Poll::Ready(Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "compressed gRPC messages are not supported",
                    )));
                }
                let len = u32::from_be_bytes([
                    self.encoded_read_buf[1],
                    self.encoded_read_buf[2],
                    self.encoded_read_buf[3],
                    self.encoded_read_buf[4],
                ]) as usize;
                if self.encoded_read_buf.len() >= 5 + len {
                    let message = self.encoded_read_buf[5..5 + len].to_vec();
                    self.encoded_read_buf.drain(..5 + len);
                    self.decoded_read_buf = Bytes::from(message);
                    continue;
                }
            }

            let mut temp = [0u8; 8192];
            let mut read_buf = ReadBuf::new(&mut temp);
            match Pin::new(&mut self.inner).poll_read(cx, &mut read_buf) {
                Poll::Ready(Ok(())) => {
                    let filled = read_buf.filled();
                    if filled.is_empty() {
                        return Poll::Ready(Ok(()));
                    }
                    self.encoded_read_buf.extend_from_slice(filled);
                }
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending => return Poll::Pending,
            }
        }
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for GrpcDataStream<S> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        if self.write_buf.is_empty() {
            let len = buf.len().min(u32::MAX as usize);
            self.write_buf = Vec::with_capacity(5 + len);
            self.write_buf.push(0);
            self.write_buf
                .extend_from_slice(&(len as u32).to_be_bytes());
            self.write_buf.extend_from_slice(&buf[..len]);
            self.pending_user_len = len;
            self.write_offset = 0;
        }

        while self.write_offset < self.write_buf.len() {
            let offset = self.write_offset;
            let chunk = self.write_buf[offset..].to_vec();
            match Pin::new(&mut self.inner).poll_write(cx, &chunk) {
                Poll::Ready(Ok(0)) => {
                    return Poll::Ready(Err(io::Error::new(
                        io::ErrorKind::WriteZero,
                        "failed to write gRPC frame",
                    )));
                }
                Poll::Ready(Ok(written)) => {
                    self.write_offset += written;
                }
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending => return Poll::Pending,
            }
        }

        let written = self.pending_user_len;
        self.clear_pending_write();
        Poll::Ready(Ok(written))
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

impl<S: AsyncPing + Unpin> AsyncPing for GrpcDataStream<S> {
    fn supports_ping(&self) -> bool {
        self.inner.supports_ping()
    }

    fn poll_write_ping(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<bool>> {
        Pin::new(&mut self.inner).poll_write_ping(cx)
    }
}

impl<S: AsyncRead + AsyncWrite + AsyncPing + Send + Sync + Unpin> AsyncStream for GrpcDataStream<S> {}

impl<S: Unpin> Unpin for GrpcDataStream<S> {}

fn grpc_path(service_name: Option<String>) -> String {
    let service_name = service_name.unwrap_or_default();
    let service_name = service_name.trim().trim_matches('/');
    if service_name.is_empty() {
        "/Tun".to_string()
    } else {
        format!("/{service_name}/Tun")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_default_path() {
        assert_eq!(grpc_path(None), "/Tun");
        assert_eq!(grpc_path(Some(String::new())), "/Tun");
    }

    #[test]
    fn builds_service_path() {
        assert_eq!(grpc_path(Some("proxy".to_string())), "/proxy/Tun");
        assert_eq!(grpc_path(Some("/proxy/".to_string())), "/proxy/Tun");
    }
}
