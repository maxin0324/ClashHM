//! Clash/Xray HTTP/2 transport client wrapper.
//!
//! This is distinct from shoes h2mux and from NaiveProxy. It opens an HTTP/2
//! request stream to the configured path, then carries the inner proxy protocol
//! bytes on that stream.

use std::collections::HashMap;
use std::io;
use std::sync::Arc;

use async_trait::async_trait;
use bytes::Bytes;
use http::{Method, Request, StatusCode, Version};
use log::debug;
use tokio::sync::Mutex;

use crate::address::ResolvedLocation;
use crate::async_stream::{AsyncMessageStream, AsyncStream};
use crate::tcp::tcp_handler::{TcpClientHandler, TcpClientSetupResult};

use super::h2_multi_stream::H2MultiStream;

#[derive(Clone)]
struct H2TransportSession {
    send_request: h2::client::SendRequest<Bytes>,
    driver_handle: Arc<DriverHandle>,
}

struct DriverHandle(tokio::task::AbortHandle);

impl Drop for DriverHandle {
    fn drop(&mut self) {
        debug!("H2 transport: all session clones dropped, aborting connection driver");
        self.0.abort();
    }
}

impl H2TransportSession {
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
            .map_err(|e| io::Error::other(format!("H2 transport handshake failed: {e}")))?;

        let abort_handle = tokio::spawn(async move {
            if let Err(e) = connection.await {
                debug!("H2 transport connection ended: {e}");
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
        host: &Option<String>,
        headers: &Option<HashMap<String, String>>,
    ) -> io::Result<Box<dyn AsyncStream>> {
        let mut request = Request::builder()
            .method(Method::POST)
            .uri(path)
            .version(Version::HTTP_2);

        if let Some(host) = host {
            request = request.header("host", host);
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
            .map_err(|e| io::Error::other(format!("failed to send H2 transport request: {e}")))?;

        let response = response_future
            .await
            .map_err(|e| io::Error::other(format!("H2 transport response error: {e}")))?;

        if response.status() != StatusCode::OK {
            return Err(io::Error::other(format!(
                "H2 transport request failed with status: {}",
                response.status()
            )));
        }

        Ok(Box::new(H2MultiStream::new(
            send_stream,
            response.into_body(),
        )))
    }
}

pub struct H2TransportTcpClientHandler {
    path: String,
    host: Option<String>,
    headers: Option<HashMap<String, String>>,
    handler: Box<dyn TcpClientHandler>,
    session: Arc<Mutex<Option<H2TransportSession>>>,
}

impl std::fmt::Debug for H2TransportTcpClientHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("H2TransportTcpClientHandler")
            .field("path", &self.path)
            .field("host", &self.host)
            .finish()
    }
}

impl H2TransportTcpClientHandler {
    pub fn new(
        path: Option<String>,
        host: Option<String>,
        headers: Option<HashMap<String, String>>,
        handler: Box<dyn TcpClientHandler>,
    ) -> Self {
        let path = normalize_path(path);
        Self {
            path,
            host,
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
            .open_stream(&self.path, &self.host, &self.headers)
            .await
    }

    async fn get_or_create_session(
        &self,
        client_stream: Box<dyn AsyncStream>,
    ) -> io::Result<H2TransportSession> {
        let mut guard = self.session.lock().await;
        if let Some(ref session) = *guard {
            if session.is_ready() {
                return Ok(session.clone());
            }
        }

        let session = H2TransportSession::new(client_stream).await?;
        *guard = Some(session.clone());
        Ok(session)
    }
}

#[async_trait]
impl TcpClientHandler for H2TransportTcpClientHandler {
    async fn setup_client_tcp_stream(
        &self,
        client_stream: Box<dyn AsyncStream>,
        remote_location: ResolvedLocation,
    ) -> io::Result<TcpClientSetupResult> {
        let h2_stream = self.setup_transport_stream(client_stream).await?;
        self.handler
            .setup_client_tcp_stream(h2_stream, remote_location)
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
        let h2_stream = self.setup_transport_stream(client_stream).await?;
        self.handler
            .setup_client_udp_bidirectional(h2_stream, target)
            .await
    }
}

fn normalize_path(path: Option<String>) -> String {
    let path = path.unwrap_or_else(|| "/".to_string());
    if path.is_empty() {
        "/".to_string()
    } else if path.starts_with('/') {
        path
    } else {
        format!("/{path}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_empty_path() {
        assert_eq!(normalize_path(None), "/");
        assert_eq!(normalize_path(Some(String::new())), "/");
    }

    #[test]
    fn normalizes_relative_path() {
        assert_eq!(normalize_path(Some("h2".to_string())), "/h2");
    }

    #[test]
    fn preserves_absolute_path() {
        assert_eq!(normalize_path(Some("/h2".to_string())), "/h2");
    }
}
