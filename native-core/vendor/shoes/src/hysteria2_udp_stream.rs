use std::pin::Pin;
use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU16, Ordering};
use std::task::{Context, Poll};

use bytes::{Bytes, BytesMut};
use tokio::io::ReadBuf;
use tokio::sync::mpsc;

use crate::address::NetLocation;
use crate::async_stream::{
    AsyncFlushMessage, AsyncMessageStream, AsyncPing, AsyncReadMessage, AsyncShutdownMessage,
    AsyncWriteMessage,
};

const MAX_QUEUE: usize = 256;
const MAX_FRAGMENTED_PACKETS: usize = 256;

pub struct Hysteria2UdpMessageStream {
    connection: quinn::Connection,
    target: NetLocation,
    target_address_bytes: Bytes,
    target_address_len_bytes: Bytes,
    session_id: u32,
    next_packet_id: Arc<AtomicU16>,
    rx: mpsc::Receiver<Bytes>,
}

impl Hysteria2UdpMessageStream {
    pub fn new(connection: quinn::Connection, target: NetLocation) -> std::io::Result<Self> {
        let target_address_bytes: Bytes = target.to_string().into_bytes().into();
        let target_address_len_bytes: Bytes =
            encode_varint(target_address_bytes.len() as u64)?.into();
        let session_id = rand::random::<u32>();
        let (tx, rx) = mpsc::channel(MAX_QUEUE);
        let read_connection = connection.clone();

        tokio::spawn(async move {
            let mut fragments = FragmentAssembler::new();
            while let Ok(datagram) = read_connection.read_datagram().await {
                if let Some(payload) =
                    parse_hysteria2_datagram(session_id, &datagram, &mut fragments)
                {
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
            target_address_len_bytes,
            session_id,
            next_packet_id: Arc::new(AtomicU16::new(0)),
            rx,
        })
    }
}

impl AsyncReadMessage for Hysteria2UdpMessageStream {
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
                "Hysteria2 UDP datagram stream closed",
            ))),
            Poll::Pending => Poll::Pending,
        }
    }
}

impl AsyncWriteMessage for Hysteria2UdpMessageStream {
    fn poll_write_message(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        let packet_id = this.next_packet_id.fetch_add(1, Ordering::Relaxed);
        send_hysteria2_payload(
            &this.connection,
            this.session_id,
            packet_id,
            &this.target_address_len_bytes,
            &this.target_address_bytes,
            buf,
        )
        .map_err(|e| {
            std::io::Error::other(format!(
                "Hysteria2 UDP send to {} failed: {e}",
                this.target
            ))
        })?;
        Poll::Ready(Ok(()))
    }
}

impl AsyncFlushMessage for Hysteria2UdpMessageStream {
    fn poll_flush_message(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

impl AsyncShutdownMessage for Hysteria2UdpMessageStream {
    fn poll_shutdown_message(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

impl AsyncPing for Hysteria2UdpMessageStream {
    fn supports_ping(&self) -> bool {
        false
    }

    fn poll_write_ping(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<bool>> {
        Poll::Ready(Ok(false))
    }
}

impl AsyncMessageStream for Hysteria2UdpMessageStream {}

fn send_hysteria2_payload(
    connection: &quinn::Connection,
    session_id: u32,
    packet_id: u16,
    target_address_len_bytes: &[u8],
    target_address_bytes: &[u8],
    payload: &[u8],
) -> std::io::Result<()> {
    let max_datagram_size = connection.max_datagram_size().unwrap_or(1200);
    let first_overhead = 4 + 2 + 1 + 1 + target_address_len_bytes.len() + target_address_bytes.len();
    let other_address_len = encode_varint(0)?.into_vec();
    let other_overhead = 4 + 2 + 1 + 1 + other_address_len.len();

    if first_overhead + payload.len() <= max_datagram_size {
        let datagram = build_hysteria2_fragment(
            session_id,
            packet_id,
            0,
            1,
            target_address_len_bytes,
            target_address_bytes,
            payload,
        );
        connection
            .send_datagram(datagram)
            .map_err(|e| std::io::Error::other(format!("{e}")))?;
        return Ok(());
    }

    if max_datagram_size <= first_overhead || max_datagram_size <= other_overhead {
        return Err(std::io::Error::other("Hysteria2 UDP datagram MTU is too small"));
    }

    let first_capacity = max_datagram_size - first_overhead;
    let other_capacity = max_datagram_size - other_overhead;
    let remaining = payload.len().saturating_sub(first_capacity);
    let fragment_count = 1 + remaining.div_ceil(other_capacity);
    if fragment_count > u8::MAX as usize {
        return Err(std::io::Error::other("Hysteria2 UDP payload requires too many fragments"));
    }

    let mut offset = 0;
    for fragment_id in 0..fragment_count {
        let (address_len_bytes, address_bytes, capacity) = if fragment_id == 0 {
            (target_address_len_bytes, target_address_bytes, first_capacity)
        } else {
            (other_address_len.as_slice(), &[][..], other_capacity)
        };
        let end = std::cmp::min(offset + capacity, payload.len());
        let datagram = build_hysteria2_fragment(
            session_id,
            packet_id,
            fragment_id as u8,
            fragment_count as u8,
            address_len_bytes,
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

fn build_hysteria2_fragment(
    session_id: u32,
    packet_id: u16,
    fragment_id: u8,
    fragment_count: u8,
    address_len_bytes: &[u8],
    address_bytes: &[u8],
    payload: &[u8],
) -> Bytes {
    let mut datagram = BytesMut::with_capacity(
        4 + 2 + 1 + 1 + address_len_bytes.len() + address_bytes.len() + payload.len(),
    );
    datagram.extend_from_slice(&session_id.to_be_bytes());
    datagram.extend_from_slice(&packet_id.to_be_bytes());
    datagram.extend_from_slice(&[fragment_id, fragment_count]);
    datagram.extend_from_slice(address_len_bytes);
    datagram.extend_from_slice(address_bytes);
    datagram.extend_from_slice(payload);
    datagram.freeze()
}

fn parse_hysteria2_datagram(
    session_id: u32,
    datagram: &[u8],
    fragments: &mut FragmentAssembler,
) -> Option<Bytes> {
    if datagram.len() < 8 {
        return None;
    }
    let actual_session = u32::from_be_bytes(datagram[0..4].try_into().ok()?);
    if actual_session != session_id {
        return None;
    }
    let fragment_id = datagram[6];
    let fragment_count = datagram[7];
    if fragment_count == 0 || fragment_id >= fragment_count {
        return None;
    }
    let (address_len, address_len_bytes) = decode_varint(&datagram[8..])?;
    let payload_offset = 8 + address_len_bytes + address_len as usize;
    if payload_offset > datagram.len() {
        return None;
    }
    let payload = Bytes::copy_from_slice(&datagram[payload_offset..]);
    if fragment_count == 1 {
        return Some(payload);
    }
    let packet_id = u16::from_be_bytes(datagram[4..6].try_into().ok()?);
    fragments.push(packet_id, fragment_id, fragment_count, payload)
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

fn decode_varint(buf: &[u8]) -> Option<(u64, usize)> {
    let first = *buf.first()?;
    let length = 1usize << (first >> 6);
    if buf.len() < length {
        return None;
    }
    let mut value = (first & 0b00111111) as u64;
    for b in &buf[1..length] {
        value = (value << 8) | (*b as u64);
    }
    Some((value, length))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_single_hysteria2_datagram() {
        let session = 7u32;
        let address = b"8.8.8.8:53";
        let mut datagram = BytesMut::new();
        datagram.extend_from_slice(&session.to_be_bytes());
        datagram.extend_from_slice(&1u16.to_be_bytes());
        datagram.extend_from_slice(&[0, 1]);
        datagram.extend_from_slice(&[address.len() as u8]);
        datagram.extend_from_slice(address);
        datagram.extend_from_slice(b"payload");

        let mut fragments = FragmentAssembler::new();
        let payload = parse_hysteria2_datagram(session, &datagram, &mut fragments).unwrap();
        assert_eq!(&payload[..], b"payload");
    }

    #[test]
    fn reassembles_fragmented_hysteria2_datagram() {
        let session = 7u32;
        let address = b"8.8.8.8:53";
        let mut fragments = FragmentAssembler::new();
        let first = build_hysteria2_fragment(
            session,
            3,
            0,
            2,
            &[address.len() as u8],
            address,
            b"pay",
        );
        let second = build_hysteria2_fragment(session, 3, 1, 2, &[0], b"", b"load");

        assert!(parse_hysteria2_datagram(session, &first, &mut fragments).is_none());
        let payload = parse_hysteria2_datagram(session, &second, &mut fragments).unwrap();
        assert_eq!(&payload[..], b"payload");
    }

    #[test]
    fn reassembles_out_of_order_hysteria2_fragments() {
        let session = 7u32;
        let address = b"8.8.8.8:53";
        let mut fragments = FragmentAssembler::new();
        let first = build_hysteria2_fragment(
            session,
            4,
            0,
            3,
            &[address.len() as u8],
            address,
            b"pay",
        );
        let second = build_hysteria2_fragment(session, 4, 1, 3, &[0], b"", b"lo");
        let third = build_hysteria2_fragment(session, 4, 2, 3, &[0], b"", b"ad");

        assert!(parse_hysteria2_datagram(session, &third, &mut fragments).is_none());
        assert!(parse_hysteria2_datagram(session, &first, &mut fragments).is_none());
        let payload = parse_hysteria2_datagram(session, &second, &mut fragments).unwrap();
        assert_eq!(&payload[..], b"payload");
    }
}
