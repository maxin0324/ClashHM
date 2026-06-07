use async_trait::async_trait;
use tokio::io::AsyncWriteExt;

use crate::address::ResolvedLocation;
use crate::async_stream::AsyncStream;
use crate::tcp::tcp_handler::{TcpClientHandler, TcpClientSetupResult};
use crate::util::write_all;

#[derive(Debug)]
pub struct Hysteria2TcpClientHandler;

impl Hysteria2TcpClientHandler {
    pub fn new() -> Self {
        Self
    }
}

const FRAME_TYPE_TCP_REQUEST: u64 = 0x401;

#[async_trait]
impl TcpClientHandler for Hysteria2TcpClientHandler {
    async fn setup_client_tcp_stream(
        &self,
        mut client_stream: Box<dyn AsyncStream>,
        remote_location: ResolvedLocation,
    ) -> std::io::Result<TcpClientSetupResult> {
        let address = remote_location.location().to_string();
        let address_bytes = address.as_bytes();

        write_all(&mut client_stream, &encode_varint(FRAME_TYPE_TCP_REQUEST)?).await?;
        write_all(&mut client_stream, &encode_varint(address_bytes.len() as u64)?).await?;
        write_all(&mut client_stream, address_bytes).await?;
        write_all(&mut client_stream, &encode_varint(0)?).await?;
        client_stream.flush().await?;

        Ok(TcpClientSetupResult {
            client_stream,
            early_data: None,
        })
    }
}

#[inline]
fn encode_varint(value: u64) -> std::io::Result<Box<[u8]>> {
    if value <= 0b00111111 {
        Ok(Box::new([value as u8]))
    } else if value < (1 << 14) {
        let mut bytes = (value as u16).to_be_bytes();
        bytes[0] |= 0b01000000;
        Ok(Box::new(bytes))
    } else if value < (1 << 30) {
        let mut bytes = (value as u32).to_be_bytes();
        bytes[0] |= 0b10000000;
        Ok(Box::new(bytes))
    } else if value < (1 << 62) {
        let mut bytes = value.to_be_bytes();
        bytes[0] |= 0b11000000;
        Ok(Box::new(bytes))
    } else {
        Err(std::io::Error::other("value too large to encode as varint"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_hysteria2_tcp_frame_type() {
        assert_eq!(&*encode_varint(FRAME_TYPE_TCP_REQUEST).unwrap(), &[0x44, 0x01]);
    }
}
