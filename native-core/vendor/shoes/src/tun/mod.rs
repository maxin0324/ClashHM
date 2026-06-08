//! TUN device support for shoes.
//!
//! This module provides VPN functionality by accepting IP packets from a TUN
//! device and routing TCP/UDP traffic through configured proxy chains.
//!
//! # Architecture
//!
//! ```text
//! ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
//! │   TUN Device    │ ←→  │  shoes/smoltcp  │ ←→  │  Proxy Chain    │
//! │ (IP packets)    │     │ (our TCP stack) │     │ (VLESS, etc.)   │
//! └─────────────────┘     └─────────────────┘     └─────────────────┘
//! ```
//!
//! The smoltcp stack runs in a dedicated OS thread with direct fd access,
//! using `select()` for efficient event-driven I/O.
//!
//! # Platform Support
//!
//! - **Linux**: Creates TUN device with specified name/address. Requires root
//!   privileges or `CAP_NET_ADMIN` capability.
//!
//! - **Android**: Accepts raw FD from `VpnService.Builder.establish()`. The
//!   VPN configuration (routes, DNS, etc.) is handled by the Android VpnService.
//!   You must pass the FD via `TunServerConfig::raw_fd()`.
//!
//! - **iOS/macOS**: Accepts raw FD from `NEPacketTunnelProvider.packetFlow`.
//!   Use `TunServerConfig::packet_information(true)` if using the socket FD
//!   directly, or `false` if using the readPackets/writePackets API.

mod tcp_conn;
pub mod fake_dns;
mod tcp_stack_direct;
mod tun_server;
mod udp_handler;
mod udp_manager;

// Platform module only needed for mobile FFI targets
#[cfg(any(target_os = "android", target_os = "ios", feature = "ffi"))]
mod platform;
#[cfg(any(target_os = "android", target_os = "ios", feature = "ffi"))]
pub use platform::{
    FnSocketProtector, NoOpPlatformCallbacks, NoOpSocketProtector, PlatformCallbacks,
    PlatformInterface, SocketProtector, get_global_socket_protector, protect_socket,
    set_global_socket_protector,
};

pub use tun_server::TunServerConfig;

use std::collections::{HashMap, VecDeque};
use std::net::SocketAddr;
use std::os::unix::io::IntoRawFd;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};

use log::{debug, info, warn};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

use crate::address::{Address, NetLocation};
use crate::client_proxy_selector::ClientProxySelector;
use crate::config::TunConfig;
use crate::config::selection::ConfigSelection;
use crate::resolver::{NativeResolver, Resolver};
use crate::tcp::tcp_client_handler_factory::create_tcp_client_proxy_selector;

use tcp_stack_direct::{NewTcpConnection, TcpStackDirect};
use udp_manager::TunUdpManager;

type PacketBuffer = Vec<u8>;

static UPLOAD_BYTES: AtomicU64 = AtomicU64::new(0);
static DOWNLOAD_BYTES: AtomicU64 = AtomicU64::new(0);
static ROUTE_DEBUG: OnceLock<Mutex<RouteDebug>> = OnceLock::new();

#[derive(Default)]
struct RouteDebug {
    fake_dns: String,
    tcp_target: String,
    tcp_remote: String,
    proxy_request: String,
    udp_target: String,
    tls_sni: String,
    interesting: String,
    history: Vec<String>,
}

fn route_debug() -> &'static Mutex<RouteDebug> {
    ROUTE_DEBUG.get_or_init(|| Mutex::new(RouteDebug::default()))
}

pub(crate) fn record_fake_dns_mapping(hostname: &str, ip: std::net::Ipv4Addr) {
    if let Ok(mut guard) = route_debug().lock() {
        let entry = format!("dns {hostname}->{ip}");
        guard.fake_dns = entry.clone();
        push_route_history(&mut guard, &entry);
    }
}

pub(crate) fn record_udp_target(target: &NetLocation) {
    if let Ok(mut guard) = route_debug().lock() {
        let entry = format!("udp {target}");
        guard.udp_target = target.to_string();
        push_route_history(&mut guard, &entry);
    }
}

fn record_tcp_target(target: &NetLocation) {
    if let Ok(mut guard) = route_debug().lock() {
        let entry = format!("tcp-target {target}");
        guard.tcp_target = target.to_string();
        push_route_history(&mut guard, &entry);
    }
}

fn record_tcp_remote(remote: &NetLocation) {
    if let Ok(mut guard) = route_debug().lock() {
        let entry = format!("tcp-remote {remote}");
        guard.tcp_remote = remote.to_string();
        push_route_history(&mut guard, &entry);
    }
}

pub(crate) fn record_proxy_request(protocol: &str, target: &NetLocation) {
    if let Ok(mut guard) = route_debug().lock() {
        let entry = format!("proxy-request {protocol} {target}");
        guard.proxy_request = format!("{protocol} {target}");
        push_route_history(&mut guard, &entry);
    }
}

fn record_tls_sni(hostname: &str) {
    if let Ok(mut guard) = route_debug().lock() {
        let entry = format!("tls-sni {hostname}");
        guard.tls_sni = hostname.to_string();
        push_route_history(&mut guard, &entry);
    }
}

fn push_route_history(debug: &mut RouteDebug, entry: &str) {
    if is_interesting_route(entry) {
        debug.interesting = entry.to_string();
    }
    debug.history.push(entry.to_string());
    if debug.history.len() > 16 {
        let drop_count = debug.history.len() - 16;
        debug.history.drain(0..drop_count);
    }
}

fn is_interesting_route(entry: &str) -> bool {
    let lower = entry.to_ascii_lowercase();
    lower.contains("chatgpt") || lower.contains("openai") || lower.contains("ipv6")
}

pub fn record_upload_bytes(bytes: usize) {
    UPLOAD_BYTES.fetch_add(bytes as u64, Ordering::Relaxed);
}

pub fn record_download_bytes(bytes: usize) {
    DOWNLOAD_BYTES.fetch_add(bytes as u64, Ordering::Relaxed);
}

pub fn traffic_snapshot() -> (u64, u64) {
    (
        UPLOAD_BYTES.load(Ordering::Relaxed),
        DOWNLOAD_BYTES.load(Ordering::Relaxed),
    )
}

pub fn reset_traffic_snapshot() {
    UPLOAD_BYTES.store(0, Ordering::Relaxed);
    DOWNLOAD_BYTES.store(0, Ordering::Relaxed);
}

// ---------------------------------------------------------------------------
// Connection tracker
// ---------------------------------------------------------------------------

static CONNECTION_TRACKER: OnceLock<Mutex<ConnectionTracker>> = OnceLock::new();
static NEXT_CONN_ID: AtomicU64 = AtomicU64::new(1);

const MAX_CLOSED_CONNECTIONS: usize = 128;

pub struct ConnectionRecord {
    pub id: u64,
    pub network: &'static str,
    pub host: String,
    pub destination_ip: String,
    pub destination_port: u16,
    pub source_ip: String,
    pub source_port: u16,
    pub rule: String,
    pub rule_payload: String,
    pub proxy_chain: Vec<String>,
    pub upload_bytes: u64,
    pub download_bytes: u64,
    pub closed: bool,
}

struct ConnectionTracker {
    active: HashMap<u64, ConnectionRecord>,
    closed: VecDeque<ConnectionRecord>,
}

fn connection_tracker() -> &'static Mutex<ConnectionTracker> {
    CONNECTION_TRACKER.get_or_init(|| {
        Mutex::new(ConnectionTracker {
            active: HashMap::new(),
            closed: VecDeque::new(),
        })
    })
}

pub fn register_connection(
    network: &'static str,
    host: &str,
    dest_ip: &str,
    dest_port: u16,
    src_ip: &str,
    src_port: u16,
) -> u64 {
    let id = NEXT_CONN_ID.fetch_add(1, Ordering::Relaxed);
    let record = ConnectionRecord {
        id,
        network,
        host: host.to_string(),
        destination_ip: dest_ip.to_string(),
        destination_port: dest_port,
        source_ip: src_ip.to_string(),
        source_port: src_port,
        rule: String::new(),
        rule_payload: String::new(),
        proxy_chain: Vec::new(),
        upload_bytes: 0,
        download_bytes: 0,
        closed: false,
    };
    if let Ok(mut tracker) = connection_tracker().lock() {
        tracker.active.insert(id, record);
    }
    id
}

pub fn register_connection_with_metadata(
    network: &'static str,
    host: &str,
    dest_ip: &str,
    dest_port: u16,
    src_ip: &str,
    src_port: u16,
    rule: &str,
    rule_payload: &str,
    proxy_chain: Vec<String>,
) -> u64 {
    let id = register_connection(network, host, dest_ip, dest_port, src_ip, src_port);
    set_connection_metadata(id, rule, rule_payload, proxy_chain);
    id
}

pub fn set_connection_metadata(id: u64, rule: &str, rule_payload: &str, proxy_chain: Vec<String>) {
    if let Ok(mut tracker) = connection_tracker().lock() {
        if let Some(record) = tracker.active.get_mut(&id) {
            record.rule = rule.to_string();
            record.rule_payload = rule_payload.to_string();
            record.proxy_chain = proxy_chain;
        }
    }
}

pub fn add_connection_bytes(id: u64, upload: u64, download: u64) {
    if let Ok(mut tracker) = connection_tracker().lock() {
        if let Some(record) = tracker.active.get_mut(&id) {
            record.upload_bytes = record.upload_bytes.saturating_add(upload);
            record.download_bytes = record.download_bytes.saturating_add(download);
        }
    }
}

pub fn finish_connection(id: u64) {
    if let Ok(mut tracker) = connection_tracker().lock()
        && let Some(mut record) = tracker.active.remove(&id)
    {
        record.closed = true;
        tracker.closed.push_back(record);
        while tracker.closed.len() > MAX_CLOSED_CONNECTIONS {
            tracker.closed.pop_front();
        }
    }
}

pub fn close_connection(id: u64, upload: u64, download: u64) {
    add_connection_bytes(id, upload, download);
    finish_connection(id);
}

pub fn connections_snapshot_json() -> String {
    let tracker = match connection_tracker().lock() {
        Ok(t) => t,
        Err(_) => return "[]".to_string(),
    };

    let mut out = String::from("[");
    let mut first = true;

    for record in tracker.active.values() {
        append_connection_json(&mut out, record, &mut first);
    }
    for record in &tracker.closed {
        append_connection_json(&mut out, record, &mut first);
    }

    out.push(']');
    out
}

pub fn connections_summary_json() -> String {
    let tracker = match connection_tracker().lock() {
        Ok(t) => t,
        Err(_) => return "{\"active\":0,\"closed\":0,\"sample\":null}".to_string(),
    };
    let sample = tracker
        .active
        .values()
        .next()
        .or_else(|| tracker.closed.back());

    let sample_json = if let Some(record) = sample {
        let mut out = String::new();
        let mut first = true;
        append_connection_json(&mut out, record, &mut first);
        out
    } else {
        "null".to_string()
    };

    format!(
        "{{\"active\":{},\"closed\":{},\"sample\":{}}}",
        tracker.active.len(),
        tracker.closed.len(),
        sample_json
    )
}

pub fn active_connection_count() -> usize {
    match connection_tracker().lock() {
        Ok(tracker) => tracker.active.len(),
        Err(_) => 0,
    }
}

pub fn reset_connections() {
    if let Ok(mut tracker) = connection_tracker().lock() {
        tracker.active.clear();
        tracker.closed.clear();
    }
    NEXT_CONN_ID.store(1, Ordering::Relaxed);
}

fn append_connection_json(out: &mut String, r: &ConnectionRecord, first: &mut bool) {
    if !*first {
        out.push(',');
    }
    *first = false;
    out.push_str(&format!(
        "{{\"id\":\"{}\",\"network\":\"{}\",\"host\":\"{}\",\"destinationIP\":\"{}\",\"destinationPort\":{},\"sourceIP\":\"{}\",\"sourcePort\":{},\"type\":\"{}\",\"rule\":\"{}\",\"rulePayload\":\"{}\",\"proxyChain\":[{}],\"uploadBytes\":{},\"downloadBytes\":{}}}",
        r.id,
        r.network,
        json_escape(&r.host),
        json_escape(&r.destination_ip),
        r.destination_port,
        json_escape(&r.source_ip),
        r.source_port,
        r.network.to_uppercase(),
        json_escape(&r.rule),
        json_escape(&r.rule_payload),
        r.proxy_chain
            .iter()
            .map(|hop| format!("\"{}\"", json_escape(hop)))
            .collect::<Vec<String>>()
            .join(","),
        r.upload_bytes,
        r.download_bytes,
    ));
}

struct ConnectionGuard {
    id: u64,
    finished: bool,
}

impl ConnectionGuard {
    fn new(id: u64) -> Self {
        Self {
            id,
            finished: false,
        }
    }

    fn finish(&mut self) {
        if !self.finished {
            finish_connection(self.id);
            self.finished = true;
        }
    }
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.finish();
    }
}

enum ConnectionByteDirection {
    Upload,
    Download,
}

struct CountingIo<S> {
    inner: S,
    conn_id: u64,
    read_direction: ConnectionByteDirection,
}

impl<S> CountingIo<S> {
    fn new(inner: S, conn_id: u64, read_direction: ConnectionByteDirection) -> Self {
        Self {
            inner,
            conn_id,
            read_direction,
        }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for CountingIo<S> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let result = Pin::new(&mut self.inner).poll_read(cx, buf);
        if let Poll::Ready(Ok(())) = &result {
            let n = buf.filled().len().saturating_sub(before) as u64;
            if n > 0 {
                match self.read_direction {
                    ConnectionByteDirection::Upload => add_connection_bytes(self.conn_id, n, 0),
                    ConnectionByteDirection::Download => add_connection_bytes(self.conn_id, 0, n),
                }
            }
        }
        result
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for CountingIo<S> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

pub fn route_debug_json() -> String {
    let guard = route_debug().lock().expect("route debug state poisoned");
    format!(
        "{{\"fakeDns\":\"{}\",\"tcpTarget\":\"{}\",\"tcpRemote\":\"{}\",\"proxyRequest\":\"{}\",\"udpTarget\":\"{}\",\"tlsSni\":\"{}\",\"interesting\":\"{}\",\"history\":[{}]}}",
        json_escape(&guard.fake_dns),
        json_escape(&guard.tcp_target),
        json_escape(&guard.tcp_remote),
        json_escape(&guard.proxy_request),
        json_escape(&guard.udp_target),
        json_escape(&guard.tls_sni),
        json_escape(&guard.interesting),
        guard
            .history
            .iter()
            .map(|entry| format!("\"{}\"", json_escape(entry)))
            .collect::<Vec<String>>()
            .join(",")
    )
}

fn json_escape(value: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Run the TUN server with the given configuration.
///
/// This function:
/// 1. Creates/wraps a TUN device
/// 2. Sets up our smoltcp-based TCP/IP stack with direct fd access
/// 3. The stack thread reads packets directly from TUN using select()
/// 4. Handles TCP connections through the proxy chain
/// 5. Handles UDP packets through tokio (forwarded from stack thread)
pub async fn run_tun_server(
    config: TunServerConfig,
    proxy_selector: Arc<ClientProxySelector>,
    resolver: Arc<dyn Resolver>,
    mut shutdown_rx: oneshot::Receiver<()>,
) -> std::io::Result<()> {
    info!(
        "Starting TUN server (direct mode): mtu={}, tcp={}, udp={}, icmp={}",
        config.mtu, config.tcp_enabled, config.udp_enabled, config.icmp_enabled
    );

    let (fd, close_fd_on_drop) = if let Some(fd) = config.raw_fd {
        info!("Using provided raw FD: {}", fd);
        (fd, false)
    } else {
        let tun_device = config.create_sync_device()?;
        let fd = tun_device.into_raw_fd();
        info!("Created TUN device with FD: {}", fd);
        (fd, true)
    };

    let mtu = config.mtu as usize;

    // Create the direct TCP stack (runs smoltcp in dedicated thread with select())
    let mut tcp_stack = TcpStackDirect::new(fd, mtu, close_fd_on_drop);

    // Get UDP receiver (stack thread filters UDP and sends here)
    let udp_from_stack_rx = tcp_stack.take_udp_rx().expect("udp_rx already taken");

    // Channel for sending UDP responses back (stack thread will write to TUN)
    let (udp_to_stack_tx, udp_to_stack_rx) = mpsc::unbounded_channel::<PacketBuffer>();
    tcp_stack.set_udp_response_tx(udp_to_stack_rx);

    let (tcp_conn_tx, mut tcp_conn_rx) = mpsc::unbounded_channel::<NewTcpConnection>();
    tcp_stack.set_new_conn_tx(tcp_conn_tx);

    let tcp_task: Option<JoinHandle<()>> = if config.tcp_enabled {
        let proxy_selector = proxy_selector.clone();
        let resolver = resolver.clone();

        Some(tokio::spawn(async move {
            info!("Starting TCP connection handler");

            while let Some(new_conn) = tcp_conn_rx.recv().await {
                let proxy_selector = proxy_selector.clone();
                let resolver = resolver.clone();

                tokio::spawn(async move {
                    let source_addr = new_conn.source_addr;
                    let remote_addr = new_conn.remote_addr;
                    let target = socket_addr_to_net_location(remote_addr);

                    debug!("Handling TCP connection to {:?}", target);

                    if let Err(e) =
                        handle_tcp_connection(
                            new_conn.connection,
                            source_addr,
                            target,
                            proxy_selector,
                            resolver,
                        )
                        .await
                    {
                        debug!("TCP connection to {} failed: {}", remote_addr, e);
                    }
                });
            }

            debug!("TCP connection handler ended");
        }))
    } else {
        None
    };

    let udp_task = if config.udp_enabled {
        let proxy_selector = proxy_selector.clone();
        let resolver = resolver.clone();

        Some(tokio::spawn(async move {
            handle_udp_packets(udp_from_stack_rx, udp_to_stack_tx, proxy_selector, resolver).await;
        }))
    } else {
        None
    };

    info!("TUN server started successfully");

    // Wait for shutdown signal or stack thread exit
    tokio::select! {
        _ = &mut shutdown_rx => {
            info!("TUN server shutdown requested");
        }
        _ = async {
            // Poll until stack stops running
            while tcp_stack.is_running() {
                tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
            }
        } => {
            warn!("Stack thread ended unexpectedly");
        }
    }

    if let Some(t) = tcp_task {
        t.abort();
    }
    if let Some(t) = udp_task {
        t.abort();
    }

    // tcp_stack is dropped here, which stops the stack thread

    info!("TUN server stopped");
    Ok(())
}

/// Convert a SocketAddr to a NetLocation.
fn socket_addr_to_net_location(addr: SocketAddr) -> NetLocation {
    let address = match addr.ip() {
        std::net::IpAddr::V4(v4) => Address::Ipv4(v4),
        std::net::IpAddr::V6(v6) => Address::Ipv6(v6),
    };
    fake_dns::resolve_fake_location(&NetLocation::new(address, addr.port()))
}

fn extract_host_ip(target: &NetLocation) -> (String, String) {
    match target.address() {
        Address::Hostname(h) => (h.clone(), String::new()),
        Address::Ipv4(ip) => (ip.to_string(), ip.to_string()),
        Address::Ipv6(ip) => (ip.to_string(), ip.to_string()),
    }
}

/// Handle a TCP connection by forwarding it through the proxy chain.
async fn handle_tcp_connection(
    mut connection: tcp_conn::TcpConnection,
    source_addr: SocketAddr,
    target: NetLocation,
    proxy_selector: Arc<ClientProxySelector>,
    resolver: Arc<dyn Resolver>,
) -> std::io::Result<()> {
    let (target, initial_data) = maybe_sniff_tls_sni(&mut connection, target).await?;
    if matches!(target.address(), Address::Ipv6(_)) && !fake_dns::ipv6_enabled() {
        debug!("TCP: dropping IPv6 target {} (ipv6 disabled)", target);
        record_tcp_target(&NetLocation::new(
            Address::Hostname(format!("ipv6-drop-{target}")),
            target.port(),
        ));
        return Ok(());
    }
    record_tcp_target(&target);
    let (host, dest_ip) = extract_host_ip(&target);
    let dest_port = target.port();
    let target_for_log = target.to_string();
    let decision = proxy_selector.judge(target.into(), &resolver).await?;

    match decision {
        crate::client_proxy_selector::ConnectDecision::Allow {
            chain_group,
            remote_location,
        } => {
            let conn_id = register_connection_with_metadata(
                "tcp",
                &host,
                &dest_ip,
                dest_port,
                &source_addr.ip().to_string(),
                source_addr.port(),
                "MATCH",
                &target_for_log,
                chain_group.describe_for_log(),
            );
            let mut conn_guard = ConnectionGuard::new(conn_id);
            debug!(
                "TCP: connecting to {} via chain",
                remote_location.location()
            );
            record_tcp_remote(remote_location.location());

            match chain_group
                .connect_tcp(remote_location.clone(), &resolver)
                .await
            {
                Ok(setup_result) => {
                    debug!(
                        "TCP: connected to {}, starting bidirectional copy",
                        remote_location.location()
                    );

                    let remote = setup_result.client_stream;
                    if !initial_data.is_empty() {
                        add_connection_bytes(conn_id, initial_data.len() as u64, 0);
                    }
                    let mut connection =
                        CountingIo::new(connection, conn_id, ConnectionByteDirection::Upload);
                    let mut remote =
                        CountingIo::new(remote, conn_id, ConnectionByteDirection::Download);
                    if !initial_data.is_empty() {
                        remote.write_all(&initial_data).await?;
                        remote.flush().await?;
                    }
                    let result = tokio::io::copy_bidirectional(&mut connection, &mut remote).await;

                    match result {
                        Ok((client_to_remote, remote_to_client)) => {
                            debug!(
                                "TCP connection to {} completed: {} bytes sent, {} bytes received",
                                remote_location.location(),
                                client_to_remote,
                                remote_to_client
                            );
                            conn_guard.finish();
                        }
                        Err(e) => {
                            debug!(
                                "TCP connection to {} error: {}",
                                remote_location.location(),
                                e
                            );
                            set_connection_metadata(
                                conn_id,
                                "COPY_ERROR",
                                &e.to_string(),
                                chain_group.describe_for_log(),
                            );
                            conn_guard.finish();
                        }
                    }

                    Ok(())
                }
                Err(e) => {
                    warn!("Failed to connect to {}: {}", remote_location.location(), e);
                    set_connection_metadata(
                        conn_id,
                        "CONNECT_ERROR",
                        &e.to_string(),
                        chain_group.describe_for_log(),
                    );
                    conn_guard.finish();
                    Err(e)
                }
            }
        }
        crate::client_proxy_selector::ConnectDecision::Block => {
            debug!("TCP connection blocked by rules");
            let conn_id = register_connection_with_metadata(
                "tcp",
                &host,
                &dest_ip,
                dest_port,
                &source_addr.ip().to_string(),
                source_addr.port(),
                "BLOCK",
                &target_for_log,
                vec!["BLOCK".to_string()],
            );
            finish_connection(conn_id);
            Ok(())
        }
    }
}

async fn maybe_sniff_tls_sni(
    connection: &mut tcp_conn::TcpConnection,
    target: NetLocation,
) -> std::io::Result<(NetLocation, Vec<u8>)> {
    if target.port() != 443 || matches!(target.address(), Address::Hostname(_)) {
        return Ok((target, Vec::new()));
    }

    let mut initial_data = Vec::<u8>::new();
    let sniff_result = tokio::time::timeout(
        tokio::time::Duration::from_millis(700),
        read_tls_client_hello_prefix(connection, &mut initial_data),
    )
    .await;

    match sniff_result {
        Ok(Ok(())) | Err(_) => {}
        Ok(Err(e)) => return Err(e),
    }

    if let Some(hostname) = parse_tls_sni(&initial_data) {
        record_tls_sni(&hostname);
        let sniffed = NetLocation::new(Address::Hostname(hostname), target.port());
        debug!("TCP: recovered domain target {} from TLS SNI", sniffed);
        Ok((sniffed, initial_data))
    } else {
        Ok((target, initial_data))
    }
}

async fn read_tls_client_hello_prefix(
    connection: &mut tcp_conn::TcpConnection,
    out: &mut Vec<u8>,
) -> std::io::Result<()> {
    let mut buf = [0u8; 2048];
    loop {
        let n = connection.read(&mut buf).await?;
        if n == 0 {
            return Ok(());
        }
        out.extend_from_slice(&buf[..n]);
        if out.len() >= 5 {
            let record_len = u16::from_be_bytes([out[3], out[4]]) as usize;
            let needed = 5usize.saturating_add(record_len);
            if out.len() >= needed || out.len() >= 8192 {
                return Ok(());
            }
        }
    }
}

fn parse_tls_sni(data: &[u8]) -> Option<String> {
    if data.len() < 5 || data[0] != 0x16 {
        return None;
    }
    let record_len = u16::from_be_bytes([data[3], data[4]]) as usize;
    if data.len() < 5 + record_len || record_len < 4 {
        return None;
    }

    let mut pos = 5usize;
    if data[pos] != 0x01 {
        return None;
    }
    pos += 1;
    let handshake_len = read_u24(data, pos)?;
    pos += 3;
    let handshake_end = pos.checked_add(handshake_len)?;
    if handshake_end > data.len() {
        return None;
    }

    pos = pos.checked_add(2 + 32)?;
    let session_id_len = *data.get(pos)? as usize;
    pos = pos.checked_add(1 + session_id_len)?;
    let cipher_suites_len = read_u16(data, pos)? as usize;
    pos = pos.checked_add(2 + cipher_suites_len)?;
    let compression_methods_len = *data.get(pos)? as usize;
    pos = pos.checked_add(1 + compression_methods_len)?;
    if pos + 2 > handshake_end {
        return None;
    }

    let extensions_len = read_u16(data, pos)? as usize;
    pos += 2;
    let extensions_end = pos.checked_add(extensions_len)?.min(handshake_end);

    while pos + 4 <= extensions_end {
        let extension_type = read_u16(data, pos)?;
        let extension_len = read_u16(data, pos + 2)? as usize;
        pos += 4;
        if pos + extension_len > extensions_end {
            return None;
        }
        if extension_type == 0 {
            return parse_sni_extension(&data[pos..pos + extension_len]);
        }
        pos += extension_len;
    }

    None
}

fn parse_sni_extension(data: &[u8]) -> Option<String> {
    if data.len() < 2 {
        return None;
    }
    let list_len = read_u16(data, 0)? as usize;
    let mut pos = 2usize;
    let end = pos.checked_add(list_len)?.min(data.len());

    while pos + 3 <= end {
        let name_type = data[pos];
        let name_len = read_u16(data, pos + 1)? as usize;
        pos += 3;
        if pos + name_len > end {
            return None;
        }
        if name_type == 0 {
            let hostname = std::str::from_utf8(&data[pos..pos + name_len]).ok()?;
            let hostname = hostname.trim_end_matches('.').to_ascii_lowercase();
            if !hostname.is_empty() {
                return Some(hostname);
            }
        }
        pos += name_len;
    }

    None
}

fn read_u16(data: &[u8], pos: usize) -> Option<u16> {
    Some(u16::from_be_bytes([*data.get(pos)?, *data.get(pos + 1)?]))
}

fn read_u24(data: &[u8], pos: usize) -> Option<usize> {
    Some(
        ((*data.get(pos)? as usize) << 16)
            | ((*data.get(pos + 1)? as usize) << 8)
            | (*data.get(pos + 2)? as usize),
    )
}

/// Handle UDP packets from the stack thread.
///
/// Uses the session-based TunUdpManager which:
/// - Keys sessions by local (app) address, not by destination
/// - Stores the return address in each session
/// - Routes responses using the stored address (no NAT table lookup)
async fn handle_udp_packets(
    from_stack_rx: mpsc::UnboundedReceiver<PacketBuffer>,
    to_stack_tx: mpsc::UnboundedSender<PacketBuffer>,
    proxy_selector: Arc<ClientProxySelector>,
    resolver: Arc<dyn Resolver>,
) {
    info!("Starting UDP handler (session-based)");

    let udp_handler = udp_handler::UdpHandler::new(from_stack_rx, to_stack_tx);
    let (reader, writer) = udp_handler.split();

    let manager = TunUdpManager::new(reader, writer, proxy_selector, resolver);

    if let Err(e) = manager.run().await {
        warn!("UDP handler error: {}", e);
    }

    info!("UDP handler stopped");
}

/// Start TUN server based on the provided configuration.
pub async fn start_tun_server(
    config: TunConfig,
    _resolver: std::sync::Arc<dyn crate::resolver::Resolver>,
) -> std::io::Result<JoinHandle<()>> {
    let (shutdown_tx, shutdown_rx) = oneshot::channel();

    let handle = tokio::spawn(async move {
        let _keep_alive = shutdown_tx;
        if let Err(e) = run_tun_from_config(config, shutdown_rx, true).await {
            warn!("TUN server error: {}", e);
        }
    });

    Ok(handle)
}

/// Run TUN server from config with external shutdown control.
pub async fn run_tun_from_config(
    config: TunConfig,
    shutdown_rx: tokio::sync::oneshot::Receiver<()>,
    close_fd_on_drop: bool,
) -> std::io::Result<()> {
    let mut tun_server_config = TunServerConfig::new()
        .mtu(config.mtu)
        .tcp_enabled(config.tcp_enabled)
        .udp_enabled(config.udp_enabled)
        .icmp_enabled(config.icmp_enabled)
        .close_fd_on_drop(close_fd_on_drop);

    if let Some(ref name) = config.device_name {
        tun_server_config = tun_server_config.tun_name(name.clone());
        println!("Starting TUN server on device {}", name);
    }
    if let Some(fd) = config.device_fd {
        tun_server_config = tun_server_config.raw_fd(fd);
        #[cfg(any(target_os = "ios", target_os = "macos"))]
        {
            tun_server_config = tun_server_config.packet_information(true);
        }
        println!("Starting TUN server from device FD {}", fd);
    }
    if let Some(addr) = config.address {
        tun_server_config = tun_server_config.address(addr);
    }
    if let Some(mask) = config.netmask {
        tun_server_config = tun_server_config.netmask(mask);
    }
    if let Some(dest) = config.destination {
        tun_server_config = tun_server_config.destination(dest);
    }

    let rules = config.rules.map(ConfigSelection::unwrap_config).into_vec();
    let resolver: Arc<dyn Resolver> = Arc::new(NativeResolver::new());
    let client_proxy_selector = Arc::new(create_tcp_client_proxy_selector(rules, resolver.clone()));

    run_tun_server(
        tun_server_config,
        client_proxy_selector,
        resolver,
        shutdown_rx,
    )
    .await
}

/// Run TUN server from config with explicit resolvers for DNS separation.
///
/// `main_resolver` is used for upstream DNS queries (may use DoH/DoT).
/// `bootstrap_resolver` is used for proxy server hostname resolution (direct, no TUN loop).
pub async fn run_tun_from_config_with_resolvers(
    config: TunConfig,
    shutdown_rx: tokio::sync::oneshot::Receiver<()>,
    close_fd_on_drop: bool,
    main_resolver: Arc<dyn Resolver>,
    bootstrap_resolver: Arc<dyn Resolver>,
) -> std::io::Result<()> {
    let mut tun_server_config = TunServerConfig::new()
        .mtu(config.mtu)
        .tcp_enabled(config.tcp_enabled)
        .udp_enabled(config.udp_enabled)
        .icmp_enabled(config.icmp_enabled)
        .close_fd_on_drop(close_fd_on_drop);

    if let Some(ref name) = config.device_name {
        tun_server_config = tun_server_config.tun_name(name.clone());
    }
    if let Some(fd) = config.device_fd {
        tun_server_config = tun_server_config.raw_fd(fd);
        #[cfg(any(target_os = "ios", target_os = "macos"))]
        {
            tun_server_config = tun_server_config.packet_information(true);
        }
    }
    if let Some(addr) = config.address {
        tun_server_config = tun_server_config.address(addr);
    }
    if let Some(mask) = config.netmask {
        tun_server_config = tun_server_config.netmask(mask);
    }
    if let Some(dest) = config.destination {
        tun_server_config = tun_server_config.destination(dest);
    }

    let rules = config.rules.map(ConfigSelection::unwrap_config).into_vec();
    let client_proxy_selector =
        Arc::new(create_tcp_client_proxy_selector(rules, bootstrap_resolver));

    run_tun_server(
        tun_server_config,
        client_proxy_selector,
        main_resolver,
        shutdown_rx,
    )
    .await
}
