use async_trait::async_trait;

use crate::address::ResolvedLocation;
use crate::async_stream::AsyncStream;
use crate::crypto::{CryptoConnection, CryptoTlsStream, perform_crypto_handshake};
use crate::fingerprint::{FingerprintTlsClientConfig, FingerprintTlsClientConnection};
use crate::tcp::tcp_handler::{TcpClientHandler, TcpClientSetupResult};

#[derive(Debug)]
pub struct FingerprintTlsClientHandler {
    config: FingerprintTlsClientConfig,
    handler: FingerprintInnerClientHandler,
}

#[derive(Debug)]
pub enum FingerprintInnerClientHandler {
    Default(Box<dyn TcpClientHandler>),
    VisionVless { uuid: Box<[u8]>, udp_enabled: bool },
}

impl FingerprintTlsClientHandler {
    pub fn new(config: FingerprintTlsClientConfig, handler: Box<dyn TcpClientHandler>) -> Self {
        Self {
            config,
            handler: FingerprintInnerClientHandler::Default(handler),
        }
    }

    pub fn new_vision_vless(
        config: FingerprintTlsClientConfig,
        user_id: Box<[u8]>,
        udp_enabled: bool,
    ) -> Self {
        Self {
            config,
            handler: FingerprintInnerClientHandler::VisionVless {
                uuid: user_id,
                udp_enabled,
            },
        }
    }

    async fn setup_client_stream_common(
        &self,
        mut client_stream: Box<dyn AsyncStream>,
    ) -> std::io::Result<CryptoTlsStream<Box<dyn AsyncStream>>> {
        let conn = FingerprintTlsClientConnection::new(self.config.clone())?;
        let mut connection = CryptoConnection::new_fingerprint_client(conn);

        perform_crypto_handshake(&mut connection, &mut client_stream, 16384).await?;

        Ok(CryptoTlsStream::new(client_stream, connection))
    }
}

#[async_trait]
impl TcpClientHandler for FingerprintTlsClientHandler {
    async fn setup_client_tcp_stream(
        &self,
        client_stream: Box<dyn AsyncStream>,
        remote_location: ResolvedLocation,
    ) -> std::io::Result<TcpClientSetupResult> {
        let tls_stream = self.setup_client_stream_common(client_stream).await?;

        match self.handler {
            FingerprintInnerClientHandler::Default(ref handler) => {
                handler
                    .setup_client_tcp_stream(Box::new(tls_stream), remote_location)
                    .await
            }
            FingerprintInnerClientHandler::VisionVless { ref uuid, .. } => {
                crate::vless::vless_client_handler::setup_custom_tls_vision_vless_client_stream(
                    tls_stream,
                    uuid,
                    remote_location.location(),
                )
                .await
            }
        }
    }

    fn supports_udp_over_tcp(&self) -> bool {
        match &self.handler {
            FingerprintInnerClientHandler::Default(handler) => handler.supports_udp_over_tcp(),
            FingerprintInnerClientHandler::VisionVless { udp_enabled, .. } => *udp_enabled,
        }
    }

    async fn setup_client_udp_bidirectional(
        &self,
        client_stream: Box<dyn AsyncStream>,
        target: ResolvedLocation,
    ) -> std::io::Result<Box<dyn crate::async_stream::AsyncMessageStream>> {
        let tls_stream = self.setup_client_stream_common(client_stream).await?;

        match &self.handler {
            FingerprintInnerClientHandler::Default(handler) => {
                handler
                    .setup_client_udp_bidirectional(Box::new(tls_stream), target)
                    .await
            }
            FingerprintInnerClientHandler::VisionVless { uuid, .. } => {
                crate::vless::vless_client_handler::setup_vless_udp_bidirectional(
                    tls_stream,
                    uuid,
                    target.into_location(),
                )
                .await
            }
        }
    }
}
