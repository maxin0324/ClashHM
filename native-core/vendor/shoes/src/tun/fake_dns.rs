use std::net::Ipv4Addr;
use std::num::NonZeroUsize;
use std::sync::{Mutex, OnceLock};

use lru::LruCache;

use crate::address::{Address, NetLocation};

const FAKE_IP_POOL_SIZE: usize = 65534;
const DNS_HEADER_LEN: usize = 12;
const TYPE_A: u16 = 1;
const TYPE_AAAA: u16 = 28;
const CLASS_IN: u16 = 1;
const DEFAULT_TTL_SECONDS: u32 = 60;

#[derive(Clone, Debug)]
pub enum FakeIpFilterEntry {
    Exact(String),
    Suffix(String),
    Keyword(String),
}

#[derive(Clone, Debug)]
pub struct FakeDnsConfig {
    pub enabled: bool,
    pub ipv6_enabled: bool,
    pub fake_ip_range_base: Ipv4Addr,
    pub fake_ip_range_prefix: u8,
    pub fake_ip_filter: Vec<FakeIpFilterEntry>,
}

impl Default for FakeDnsConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            ipv6_enabled: false,
            fake_ip_range_base: Ipv4Addr::new(198, 18, 0, 0),
            fake_ip_range_prefix: 16,
            fake_ip_filter: Vec::new(),
        }
    }
}

struct FakeDnsState {
    config: FakeDnsConfig,
    next_host: u32,
    host_to_ip: LruCache<String, Ipv4Addr>,
    ip_to_host: LruCache<Ipv4Addr, String>,
    host_to_real_ipv4: LruCache<String, Ipv4Addr>,
}

impl FakeDnsState {
    fn new(config: FakeDnsConfig) -> Self {
        let cap = NonZeroUsize::new(FAKE_IP_POOL_SIZE).unwrap();
        Self {
            config,
            next_host: 0,
            host_to_ip: LruCache::new(cap),
            ip_to_host: LruCache::new(cap),
            host_to_real_ipv4: LruCache::new(cap),
        }
    }
}

impl Default for FakeDnsState {
    fn default() -> Self {
        Self::new(FakeDnsConfig::default())
    }
}

static STATE: OnceLock<Mutex<FakeDnsState>> = OnceLock::new();

fn state() -> &'static Mutex<FakeDnsState> {
    STATE.get_or_init(|| Mutex::new(FakeDnsState::default()))
}

pub fn init(config: FakeDnsConfig) {
    let mut guard = state().lock().expect("fake dns state poisoned");
    *guard = FakeDnsState::new(config);
}

pub fn ipv6_enabled() -> bool {
    state()
        .lock()
        .map(|g| g.config.ipv6_enabled)
        .unwrap_or(false)
}

pub fn resolve_fake_location(location: &NetLocation) -> NetLocation {
    let Address::Ipv4(ip) = location.address() else {
        return location.clone();
    };
    let Some(hostname) = lookup_hostname(*ip) else {
        return location.clone();
    };
    NetLocation::new(Address::Hostname(hostname), location.port())
}

pub fn real_ipv4_for_location(location: &NetLocation) -> Option<Ipv4Addr> {
    let hostname = location.address().hostname()?;
    let normalized = normalize_hostname(hostname);
    state()
        .lock()
        .ok()?
        .host_to_real_ipv4
        .get(&normalized)
        .copied()
}

pub fn is_a_query(query: &[u8]) -> bool {
    parse_query(query)
        .map(|parsed| parsed.qclass == CLASS_IN && parsed.qtype == TYPE_A)
        .unwrap_or(false)
}

pub fn learn_ipv4_answers(response: &[u8]) {
    let Some((hostname, answers_start, answer_count)) = parse_response_question(response) else {
        return;
    };
    let mut pos = answers_start;
    for _ in 0..answer_count {
        let Some(next_pos) = skip_dns_name(response, pos) else {
            return;
        };
        pos = next_pos;
        if pos + 10 > response.len() {
            return;
        }
        let rr_type = u16::from_be_bytes([response[pos], response[pos + 1]]);
        let rr_class = u16::from_be_bytes([response[pos + 2], response[pos + 3]]);
        let rdlen = u16::from_be_bytes([response[pos + 8], response[pos + 9]]) as usize;
        pos += 10;
        if pos + rdlen > response.len() {
            return;
        }
        if rr_type == TYPE_A && rr_class == CLASS_IN && rdlen == 4 {
            let ip = Ipv4Addr::new(
                response[pos],
                response[pos + 1],
                response[pos + 2],
                response[pos + 3],
            );
            if let Ok(mut guard) = state().lock() {
                guard.host_to_real_ipv4.push(hostname.clone(), ip);
            }
            return;
        }
        pos += rdlen;
    }
}

fn lookup_hostname(ip: Ipv4Addr) -> Option<String> {
    if !is_fake_ip(ip) {
        return None;
    }
    state().lock().ok()?.ip_to_host.get(&ip).cloned()
}

fn is_fake_ip(ip: Ipv4Addr) -> bool {
    let Ok(guard) = state().lock() else {
        return false;
    };
    is_fake_ip_in_config(ip, &guard.config)
}

fn is_fake_ip_in_config(ip: Ipv4Addr, config: &FakeDnsConfig) -> bool {
    if !config.enabled {
        return false;
    }
    let mask = prefix_mask(config.fake_ip_range_prefix);
    (u32::from(ip) & mask) == (u32::from(config.fake_ip_range_base) & mask)
}

fn prefix_mask(prefix: u8) -> u32 {
    if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix.min(32))
    }
}

fn fake_ip_capacity(prefix: u8) -> u32 {
    if prefix >= 31 {
        1
    } else {
        let host_bits = 32 - prefix.min(32);
        ((1u64 << host_bits).saturating_sub(2)).min(FAKE_IP_POOL_SIZE as u64) as u32
    }
}

fn fake_ip_from_host(config: &FakeDnsConfig, host: u32) -> Ipv4Addr {
    let prefix = config.fake_ip_range_prefix.min(32);
    let mask = prefix_mask(prefix);
    let base = u32::from(config.fake_ip_range_base) & mask;
    let host_mask = !mask;
    Ipv4Addr::from(base | (host & host_mask))
}

fn allocate_fake_ip(hostname: &str) -> Ipv4Addr {
    let normalized = normalize_hostname(hostname);
    let mut guard = state().lock().expect("fake dns state poisoned");
    if let Some(ip) = guard.host_to_ip.get(&normalized) {
        return *ip;
    }

    let capacity = fake_ip_capacity(guard.config.fake_ip_range_prefix);
    let ip = loop {
        guard.next_host = (guard.next_host % capacity) + 1;
        let host = guard.next_host;
        let candidate = fake_ip_from_host(&guard.config, host);
        if guard.ip_to_host.peek(&candidate).is_none() {
            break candidate;
        }
        // All IPs occupied — evict the LRU entry to free one
        if guard.ip_to_host.len() >= FAKE_IP_POOL_SIZE {
            if let Some((_evicted_ip, evicted_host)) = guard.ip_to_host.pop_lru() {
                guard.host_to_ip.pop(&evicted_host);
                guard.host_to_real_ipv4.pop(&evicted_host);
                continue;
            }
        }
    };

    if let Some((evicted_host, evicted_ip)) = guard.host_to_ip.push(normalized.clone(), ip) {
        guard.ip_to_host.pop(&evicted_ip);
        guard.host_to_real_ipv4.pop(&evicted_host);
    }
    guard.ip_to_host.push(ip, normalized);
    super::record_fake_dns_mapping(hostname, ip);
    ip
}

fn normalize_hostname(hostname: &str) -> String {
    hostname.trim_end_matches('.').to_ascii_lowercase()
}

fn matches_fake_ip_filter(hostname: &str, filter: &[FakeIpFilterEntry]) -> bool {
    filter.iter().any(|entry| match entry {
        FakeIpFilterEntry::Exact(domain) => hostname == domain,
        FakeIpFilterEntry::Suffix(base) => {
            if hostname.len() == base.len() {
                hostname == base
            } else if hostname.len() > base.len() {
                hostname.ends_with(base.as_str())
                    && hostname.as_bytes()[hostname.len() - base.len() - 1] == b'.'
            } else {
                false
            }
        }
        FakeIpFilterEntry::Keyword(kw) => hostname.contains(kw.as_str()),
    })
}

pub fn handle_dns_query(query: &[u8]) -> Option<Vec<u8>> {
    let parsed = parse_query(query)?;
    if parsed.qclass != CLASS_IN {
        return None;
    }
    if !state().lock().ok()?.config.enabled {
        return None;
    }

    match parsed.qtype {
        TYPE_A => {
            let guard = state().lock().ok()?;
            if matches_fake_ip_filter(&parsed.hostname, &guard.config.fake_ip_filter) {
                return None;
            }
            drop(guard);
            let fake_ip = allocate_fake_ip(&parsed.hostname);
            Some(build_response(query, &parsed, Some(fake_ip)))
        }
        TYPE_AAAA => {
            let guard = state().lock().ok()?;
            if guard.config.ipv6_enabled {
                None
            } else {
                Some(build_response(query, &parsed, None))
            }
        }
        _ => None,
    }
}

struct ParsedQuery {
    id: [u8; 2],
    question_end: usize,
    hostname: String,
    qtype: u16,
    qclass: u16,
}

fn parse_query(packet: &[u8]) -> Option<ParsedQuery> {
    if packet.len() < DNS_HEADER_LEN {
        return None;
    }
    let qdcount = u16::from_be_bytes([packet[4], packet[5]]);
    if qdcount != 1 {
        return None;
    }

    let mut pos = DNS_HEADER_LEN;
    let mut labels = Vec::<String>::new();
    while pos < packet.len() {
        let len = packet[pos] as usize;
        pos += 1;
        if len == 0 {
            break;
        }
        if len & 0xc0 != 0 || len > 63 || pos + len > packet.len() {
            return None;
        }
        let label = std::str::from_utf8(&packet[pos..pos + len]).ok()?;
        labels.push(label.to_ascii_lowercase());
        pos += len;
    }

    if labels.is_empty() || pos + 4 > packet.len() {
        return None;
    }

    let qtype = u16::from_be_bytes([packet[pos], packet[pos + 1]]);
    let qclass = u16::from_be_bytes([packet[pos + 2], packet[pos + 3]]);
    Some(ParsedQuery {
        id: [packet[0], packet[1]],
        question_end: pos + 4,
        hostname: normalize_hostname(&labels.join(".")),
        qtype,
        qclass,
    })
}

fn parse_response_question(packet: &[u8]) -> Option<(String, usize, u16)> {
    if packet.len() < DNS_HEADER_LEN {
        return None;
    }
    let qdcount = u16::from_be_bytes([packet[4], packet[5]]);
    let ancount = u16::from_be_bytes([packet[6], packet[7]]);
    if qdcount != 1 || ancount == 0 {
        return None;
    }
    let parsed = parse_query(packet)?;
    Some((parsed.hostname, parsed.question_end, ancount))
}

fn skip_dns_name(packet: &[u8], mut pos: usize) -> Option<usize> {
    while pos < packet.len() {
        let len = packet[pos];
        pos += 1;
        if len == 0 {
            return Some(pos);
        }
        if len & 0xc0 == 0xc0 {
            if pos >= packet.len() {
                return None;
            }
            return Some(pos + 1);
        }
        if len & 0xc0 != 0 {
            return None;
        }
        pos = pos.checked_add(len as usize)?;
        if pos > packet.len() {
            return None;
        }
    }
    None
}

fn build_response(query: &[u8], parsed: &ParsedQuery, answer: Option<Ipv4Addr>) -> Vec<u8> {
    let answer_count = if answer.is_some() { 1u16 } else { 0u16 };
    let mut response = Vec::with_capacity(parsed.question_end + 16);

    response.extend_from_slice(&parsed.id);
    response.extend_from_slice(&0x8180u16.to_be_bytes());
    response.extend_from_slice(&1u16.to_be_bytes());
    response.extend_from_slice(&answer_count.to_be_bytes());
    response.extend_from_slice(&0u16.to_be_bytes());
    response.extend_from_slice(&0u16.to_be_bytes());
    response.extend_from_slice(&query[DNS_HEADER_LEN..parsed.question_end]);

    if let Some(ip) = answer {
        response.extend_from_slice(&0xc00cu16.to_be_bytes());
        response.extend_from_slice(&TYPE_A.to_be_bytes());
        response.extend_from_slice(&CLASS_IN.to_be_bytes());
        response.extend_from_slice(&DEFAULT_TTL_SECONDS.to_be_bytes());
        response.extend_from_slice(&4u16.to_be_bytes());
        response.extend_from_slice(&ip.octets());
    }

    response
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as TestMutex;

    static TEST_LOCK: TestMutex<()> = TestMutex::new(());

    fn query(hostname: &str, qtype: u16) -> Vec<u8> {
        let mut packet = Vec::new();
        packet.extend_from_slice(&0x1234u16.to_be_bytes());
        packet.extend_from_slice(&0x0100u16.to_be_bytes());
        packet.extend_from_slice(&1u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        for label in hostname.split('.') {
            packet.push(label.len() as u8);
            packet.extend_from_slice(label.as_bytes());
        }
        packet.push(0);
        packet.extend_from_slice(&qtype.to_be_bytes());
        packet.extend_from_slice(&CLASS_IN.to_be_bytes());
        packet
    }

    #[test]
    fn returns_stable_fake_ip_for_a_query() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        init(FakeDnsConfig::default());

        let response = handle_dns_query(&query("stable-test.com", TYPE_A)).unwrap();
        assert_eq!(&response[0..2], &[0x12, 0x34]);
        assert_eq!(u16::from_be_bytes([response[6], response[7]]), 1);
        let ip = Ipv4Addr::new(
            response[response.len() - 4],
            response[response.len() - 3],
            response[response.len() - 2],
            response[response.len() - 1],
        );
        assert!(is_fake_ip(ip));

        let location = NetLocation::new(Address::Ipv4(ip), 443);
        assert_eq!(
            resolve_fake_location(&location).to_string(),
            "stable-test.com:443"
        );
    }

    #[test]
    fn returns_no_data_for_aaaa_query() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        init(FakeDnsConfig::default());

        let response = handle_dns_query(&query("aaaa-test.com", TYPE_AAAA)).unwrap();
        assert_eq!(u16::from_be_bytes([response[6], response[7]]), 0);
    }

    #[test]
    fn learns_real_ipv4_from_upstream_response() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        init(FakeDnsConfig::default());

        let mut response = query("learn-test.com", TYPE_A);
        response[2] = 0x81;
        response[3] = 0x80;
        response[6] = 0;
        response[7] = 1;
        response.extend_from_slice(&0xc00cu16.to_be_bytes());
        response.extend_from_slice(&TYPE_A.to_be_bytes());
        response.extend_from_slice(&CLASS_IN.to_be_bytes());
        response.extend_from_slice(&60u32.to_be_bytes());
        response.extend_from_slice(&4u16.to_be_bytes());
        response.extend_from_slice(&[1, 2, 3, 4]);

        learn_ipv4_answers(&response);

        let location = NetLocation::new(Address::Hostname("learn-test.com".to_string()), 443);
        assert_eq!(real_ipv4_for_location(&location), Some(Ipv4Addr::new(1, 2, 3, 4)));
    }

    #[test]
    fn fake_ip_filter_exact_match() {
        let filter = vec![FakeIpFilterEntry::Exact("dns.google".to_string())];
        assert!(matches_fake_ip_filter("dns.google", &filter));
        assert!(!matches_fake_ip_filter("other.dns.google", &filter));
        assert!(!matches_fake_ip_filter("google.com", &filter));
    }

    #[test]
    fn fake_ip_filter_suffix_match() {
        let filter = vec![FakeIpFilterEntry::Suffix("example.com".to_string())];
        assert!(matches_fake_ip_filter("example.com", &filter));
        assert!(matches_fake_ip_filter("sub.example.com", &filter));
        assert!(matches_fake_ip_filter("deep.sub.example.com", &filter));
        assert!(!matches_fake_ip_filter("fakeexample.com", &filter));
        assert!(!matches_fake_ip_filter("other.com", &filter));
    }

    #[test]
    fn fake_ip_filter_keyword_match() {
        let filter = vec![FakeIpFilterEntry::Keyword("microsoft".to_string())];
        assert!(matches_fake_ip_filter("login.microsoft.com", &filter));
        assert!(matches_fake_ip_filter("microsoft.com", &filter));
        assert!(!matches_fake_ip_filter("google.com", &filter));
    }

    #[test]
    fn ipv6_enabled_passes_aaaa_through() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        init(FakeDnsConfig {
            ipv6_enabled: true,
            fake_ip_filter: vec![],
            ..FakeDnsConfig::default()
        });
        assert!(handle_dns_query(&query("test-ipv6.com", TYPE_AAAA)).is_none());
        init(FakeDnsConfig::default());
    }

    #[test]
    fn filtered_domain_returns_none_for_a_query() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        init(FakeDnsConfig {
            ipv6_enabled: false,
            fake_ip_filter: vec![FakeIpFilterEntry::Suffix("filtered.com".to_string())],
            ..FakeDnsConfig::default()
        });
        assert!(handle_dns_query(&query("app.filtered.com", TYPE_A)).is_none());
        assert!(handle_dns_query(&query("unfiltered.com", TYPE_A)).is_some());
        init(FakeDnsConfig::default());
    }
}
