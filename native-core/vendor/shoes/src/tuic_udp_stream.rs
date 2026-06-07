use std::collections::BTreeMap;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicU16, Ordering};
use std::task::{Context, Poll};

use bytes::{Bytes, BytesMut};
use tokio::io::ReadBuf;
use tokio::sync::mpsc;

use crate::address::{Address, NetLocation};
use crate::async_stream::{
    AsyncFlushMessage, AsyncMessageStream, AsyncPing, AsyncReadMessage, AsyncShutdownMessage,
    AsyncWriteMessage,
};

const MAX_QUEUE: usize = 256;
const MAX_FRAGMENTED_PACKETS: usize = 256;
const TUIC_VERSION: u8 = 5;
const COMMAND_TYPE_PACKET: u8 = 0x02;
const COMMAND_TYPE_HEARTBEAT: u8 = 0x04;

pub struct TuicUdpMessageStream {
    connection: quinn::Connection,
    target: NetLocation,
    target_address_bytes: Bytes,
    assoc_id: u16,
    next_packet_id: Arc<AtomicU16>,
    rx: mpsc::Receiver<Bytes>,
}

impl TuicUdpMessageStream {
    pub fn new(connection: quinn::Connection, target: NetLocation) -> std::io::Result<Self> {
        let target_address_bytes: Bytes = serialize_address(&target).into();
        let assoc_id = rand::random::<u16>();
        let (tx, rx) = mpsc::channel(MAX_QUEUE);
        let read_connection = connection.clone();

        tokio::spawn(async move {
            let mut fragments = FragmentAssembler::new();
            while let Ok(datagram) = read_connection.read_datagram().await {
                if let Some(payload) = parse_tuic_datagram(assoc_id, &datagram, &mut fragments) {
                    if tx.send(payload).await.is_err() {
                        break;
                    }
                }
            }
        });

        Ok(Self {
            connection,
            target,
            target_address_bytes,
            assoc_id,
            next_packet_id: Arc::new(AtomicU16::new(0)),
            rx,
        })
    }
}

impl AsyncReadMessage for TuicUdpMessageStream {
    fn poll_read_message(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        match Pin::new(&mut this.rx).poll_recv(cx) {
            Poll::Ready(Some(payload)) => {
                let copy_len = std::cmp::min(buf.remaining(), payload.len());
                buf.put_slice(&payload[..copy_len]);
                Poll::Ready(Ok(()))
            }
            Poll::Ready(None) => Poll::Ready(Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "TUIC UDP datagram stream closed",
            ))),
            Poll::Pending => Poll::Pending,
        }
    }
}

impl AsyncWriteMessage for TuicUdpMessageStream {
    fn poll_write_message(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        let packet_id = this.next_packet_id.fetch_add(1, Ordering::Relaxed);
        send_tuic_payload(
            &this.connection,
            this.assoc_id,
            packet_id,
            &this.target_address_bytes,
            buf,
        )
        .map_err(|e| {
            std::io::Error::other(format!("TUIC UDP send to {} failed: {e}", this.target))
        })?;
        Poll::Ready(Ok(()))
    }
}

impl AsyncFlushMessage for TuicUdpMessageStream {
    fn poll_flush_message(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

impl AsyncShutdownMessage for TuicUdpMessageStream {
    fn poll_shutdown_message(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

impl AsyncPing for TuicUdpMessageStream {
    fn supports_ping(&self) -> bool {
        false
    }

    fn poll_write_ping(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<bool>> {
        Poll::Ready(Ok(false))
    }
}

impl AsyncMessageStream for TuicUdpMessageStream {}

fn send_tuic_payload(
    connection: &quinn::Connection,
    assoc_id: u16,
    packet_id: u16,
    target_address_bytes: &[u8],
    payload: &[u8],
) -> std::io::Result<()> {
    let max_datagram_size = connection.max_datagram_size().unwrap_or(1200);
    let first_overhead = 10 + target_address_bytes.len();
    let other_overhead = 11;

    if first_overhead + payload.len() <= max_datagram_size {
        let datagram = build_tuic_fragment(assoc_id, packet_id, 1, 0, target_address_bytes, payload);
        connection
            .send_datagram(datagram)
            .map_err(|e| std::io::Error::other(format!("{e}")))?;
        return Ok(());
    }

    if max_datagram_size <= first_overhead || max_datagram_size <= other_overhead {
        return Err(std::io::Error::other("TUIC UDP datagram MTU is too small"));
    }

    let first_capacity = max_datagram_size - first_overhead;
    let other_capacity = max_datagram_size - other_overhead;
    let remaining = payload.len().saturating_sub(first_capacity);
    let fragment_count = 1 + remaining.div_ceil(other_capacity);
    if fragment_count > u8::MAX as usize {
        return Err(std::io::Error::other("TUIC UDP payload requires too many fragments"));
    }

    let mut offset = 0;
    for fragment_id in 0..fragment_count {
        let (address_bytes, capacity) = if fragment_id == 0 {
            (target_address_bytes, first_capacity)
        } else {
            (&[0xff][..], other_capacity)
        };
        let end = std::cmp::min(offset + capacity, payload.len());
        let datagram = build_tuic_fragment(
            assoc_id,
            packet_id,
            fragment_count as u8,
            fragment_id as u8,
            address_bytes,
            &payload[offset..end],
        );
        connection
            .send_datagram(datagram)
            .map_err(|e| std::io::Error::other(format!("{e}")))?;
        offset = end;
    }
    Ok(())
}

fn build_tuic_fragment(
    assoc_id: u16,
    packet_id: u16,
    fragment_count: u8,
    fragment_id: u8,
    address_bytes: &[u8],
    payload: &[u8],
) -> Bytes {
    let mut datagram = BytesMut::with_capacity(10 + address_bytes.len() + payload.len());
    datagram.extend_from_slice(&[TUIC_VERSION, COMMAND_TYPE_PACKET]);
    datagram.extend_from_slice(&assoc_id.to_be_bytes());
    datagram.extend_from_slice(&packet_id.to_be_bytes());
    datagram.extend_from_slice(&[fragment_count, fragment_id]);
    datagram.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    datagram.extend_from_slice(address_bytes);
    datagram.extend_from_slice(payload);
    datagram.freeze()
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

fn parse_tuic_datagram(
    assoc_id: u16,
    datagram: &[u8],
    fragments: &mut FragmentAssembler,
) -> Option<Bytes> {
    if datagram.len() < 2 {
        return None;
    }
    if datagram[0] != TUIC_VERSION {
        return None;
    }
    if datagram[1] == COMMAND_TYPE_HEARTBEAT {
        return None;
    }
    if datagram[1] != COMMAND_TYPE_PACKET || datagram.len() < 11 {
        return None;
    }
    let actual_assoc = u16::from_be_bytes(datagram[2..4].try_into().ok()?);
    if actual_assoc != assoc_id {
        return None;
    }
    let frag_total = datagram[6];
    let frag_id = datagram[7];
    if frag_total == 0 || frag_id >= frag_total {
        return None;
    }
    let payload_size = u16::from_be_bytes(datagram[8..10].try_into().ok()?) as usize;
    let offset = address_payload_offset(datagram)?;
    if offset + payload_size > datagram.len() {
        return None;
    }
    let payload = Bytes::copy_from_slice(&datagram[offset..offset + payload_size]);
    if frag_total == 1 {
        return Some(payload);
    }
    let packet_id = u16::from_be_bytes(datagram[4..6].try_into().ok()?);
    fragments.push(packet_id, frag_id, frag_total, payload)
}

fn address_payload_offset(datagram: &[u8]) -> Option<usize> {
    match *datagram.get(10)? {
        0xff => Some(11),
        0x00 => {
            let len = *datagram.get(11)? as usize;
            Some(12 + len + 2)
        }
        0x01 => Some(17),
        0x02 => Some(29),
        _ => None,
    }
}

struct FragmentAssembler {
    packets: BTreeMap<u16, FragmentedPacket>,
}

struct FragmentedPacket {
    total: u8,
    received: Vec<Option<Bytes>>,
    received_count: u8,
}

impl FragmentAssembler {
    fn new() -> Self {
        Self {
            packets: BTreeMap::new(),
        }
    }

    fn push(
        &mut self,
        packet_id: u16,
        fragment_id: u8,
        fragment_count: u8,
        payload: Bytes,
    ) -> Option<Bytes> {
        if self.packets.len() >= MAX_FRAGMENTED_PACKETS
            && !self.packets.contains_key(&packet_id)
            && let Some(first_key) = self.packets.keys().next().copied()
        {
            self.packets.remove(&first_key);
        }
        let packet = self.packets.entry(packet_id).or_insert_with(|| FragmentedPacket {
            total: fragment_count,
            received: vec![None; fragment_count as usize],
            received_count: 0,
        });
        if packet.total != fragment_count {
            self.packets.remove(&packet_id);
            return None;
        }
        let slot = packet.received.get_mut(fragment_id as usize)?;
        if slot.is_some() {
            return None;
        }
        *slot = Some(payload);
        packet.received_count += 1;
        if packet.received_count != packet.total {
            return None;
        }
        let packet = self.packets.remove(&packet_id)?;
        let len = packet
            .received
            .iter()
            .map(|part| part.as_ref().map(|p| p.len()).unwrap_or(0))
            .sum();
        let mut out = BytesMut::with_capacity(len);
        for part in packet.received {
            out.extend_from_slice(&part?);
        }
        Some(out.freeze())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_single_tuic_datagram() {
        let assoc = 9u16;
        let address = serialize_address(&NetLocation::from_str("8.8.8.8:53", None).unwrap());
        let mut datagram = BytesMut::new();
        datagram.extend_from_slice(&[TUIC_VERSION, COMMAND_TYPE_PACKET]);
        datagram.extend_from_slice(&assoc.to_be_bytes());
        datagram.extend_from_slice(&1u16.to_be_bytes());
        datagram.extend_from_slice(&[1, 0]);
        datagram.extend_from_slice(&7u16.to_be_bytes());
        datagram.extend_from_slice(&address);
        datagram.extend_from_slice(b"payload");

        let mut fragments = FragmentAssembler::new();
        let payload = parse_tuic_datagram(assoc, &datagram, &mut fragments).unwrap();
        assert_eq!(&payload[..], b"payload");
    }

    #[test]
    fn reassembles_fragmented_tuic_datagram() {
        let assoc = 9u16;
        let address = serialize_address(&NetLocation::from_str("8.8.8.8:53", None).unwrap());
        let mut fragments = FragmentAssembler::new();
        let first = build_tuic_fragment(assoc, 4, 2, 0, &address, b"pay");
        let second = build_tuic_fragment(assoc, 4, 2, 1, &[0xff], b"load");

        assert!(parse_tuic_datagram(assoc, &first, &mut fragments).is_none());
        let payload = parse_tuic_datagram(assoc, &second, &mut fragments).unwrap();
        assert_eq!(&payload[..], b"payload");
    }

    #[test]
    fn reassembles_out_of_order_tuic_fragments() {
        let assoc = 9u16;
        let address = serialize_address(&NetLocation::from_str("8.8.8.8:53", None).unwrap());
        let mut fragments = FragmentAssembler::new();
        let first = build_tuic_fragment(assoc, 5, 3, 0, &address, b"pay");
        let second = build_tuic_fragment(assoc, 5, 3, 1, &[0xff], b"lo");
        let third = build_tuic_fragment(assoc, 5, 3, 2, &[0xff], b"ad");

        assert!(parse_tuic_datagram(assoc, &third, &mut fragments).is_none());
        assert!(parse_tuic_datagram(assoc, &first, &mut fragments).is_none());
        let payload = parse_tuic_datagram(assoc, &second, &mut fragments).unwrap();
        assert_eq!(&payload[..], b"payload");
    }
}
