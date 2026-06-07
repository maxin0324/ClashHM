use std::net::{Ipv4Addr, Ipv6Addr};

use async_trait::async_trait;
use tokio::io::AsyncWriteExt;

use crate::address::{Address, NetLocation, ResolvedLocation};
use crate::async_stream::AsyncStream;
use crate::tcp::tcp_handler::{TcpClientHandler, TcpClientSetupResult};
use crate::util::write_all;

#[derive(Debug)]
pub struct TuicTcpClientHandler;

impl TuicTcpClientHandler {
    pub fn new() -> Self {
        Self
    }
}

const TUIC_VERSION: u8 = 5;
const COMMAND_TYPE_CONNECT: u8 = 0x01;

#[async_trait]
impl TcpClientHandler for TuicTcpClientHandler {
    async fn setup_client_tcp_stream(
        &self,
        mut client_stream: Box<dyn AsyncStream>,
        remote_location: ResolvedLocation,
    ) -> std::io::Result<TcpClientSetupResult> {
        write_all(&mut client_stream, &[TUIC_VERSION, COMMAND_TYPE_CONNECT]).await?;
        write_all(
            &mut client_stream,
            &serialize_address(remote_location.location()),
        )
        .await?;
        client_stream.flush().await?;

        Ok(TcpClientSetupResult {
            client_stream,
            early_data: None,
        })
    }
}

fn serialize_address(location: &NetLocation) -> Vec<u8> {
    let mut address_bytes = match location.address() {
        Address::Hostname(hostname) => {
            let mut res = Vec::with_capacity(1 + 1 + hostname.len() + 2);
            res.push(0x00);
            let hostname_bytes = hostname.as_bytes();
            res.push(hostname_bytes.len() as u8);
            res.extend_from_slice(hostname_bytes);
            res
        }
        Address::Ipv4(ipv4) => {
            let mut res = Vec::with_capacity(1 + 4 + 2);
            res.push(0x01);
            res.extend_from_slice(&Ipv4Addr::from(*ipv4).octets());
            res
        }
        Address::Ipv6(ipv6) => {
            let mut res = Vec::with_capacity(1 + 16 + 2);
            res.push(0x02);
            res.extend_from_slice(&Ipv6Addr::from(*ipv6).octets());
            res
        }
    };

    address_bytes.extend_from_slice(&location.port().to_be_bytes());
    address_bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serializes_hostname_address() {
        let location = NetLocation::from_str("example.com:443", None).unwrap();
        let bytes = serialize_address(&location);
        assert_eq!(bytes[0], 0x00);
        assert_eq!(bytes[1], "example.com".len() as u8);
        assert_eq!(&bytes[2..13], b"example.com");
        assert_eq!(&bytes[13..15], &443u16.to_be_bytes());
    }
}
