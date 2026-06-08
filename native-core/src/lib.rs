use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::net::{TcpStream, ToSocketAddrs};
use std::os::raw::{c_char, c_int};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const PARSER_VERSION: &str = "2026-06-08-mihomo-parity-v1";

#[cfg(feature = "shoes-backend")]
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(feature = "shoes-backend")]
use std::sync::Arc;
#[cfg(feature = "shoes-backend")]
use tokio::sync::oneshot;

#[derive(Clone, Debug, PartialEq, Eq)]
struct ProxyNode {
    name: String,
    proxy_type: String,
    fields: BTreeMap<String, String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ProxyGroup {
    name: String,
    group_type: String,
    now: String,
    all: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ClashRule {
    rule_type: String,
    payload: String,
    target: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct GeositeCategory {
    masks: Vec<String>,
    keywords: Vec<String>,
    skipped_regex: usize,
}

#[allow(dead_code)]
#[derive(Clone, Debug, Default)]
struct ClashDnsConfig {
    enabled: bool,
    ipv6: bool,
    enhanced_mode: String,
    fake_ip_range: String,
    nameservers: Vec<String>,
    default_nameservers: Vec<String>,
    fake_ip_filter: Vec<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TlsClientMode {
    Chrome,
    Rustls,
}

impl Default for TlsClientMode {
    fn default() -> Self {
        Self::Chrome
    }
}

#[derive(Clone, Debug, Default)]
struct RuntimeConfig {
    tls_client_mode: TlsClientMode,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ConnectionMode {
    Rule,
    Global,
    Direct,
}

impl ConnectionMode {
    fn as_str(self) -> &'static str {
        match self {
            ConnectionMode::Rule => "rule",
            ConnectionMode::Global => "global",
            ConnectionMode::Direct => "direct",
        }
    }
}

impl Default for ConnectionMode {
    fn default() -> Self {
        Self::Rule
    }
}

#[derive(Default)]
struct CoreState {
    home_dir: String,
    running: bool,
    tun_fd: i32,
    proxies: Vec<ProxyNode>,
    groups: Vec<ProxyGroup>,
    rules: Vec<ClashRule>,
    delay_by_proxy: BTreeMap<String, i32>,
    status: String,
    engine: String,
    started_at_ms: u128,
    last_error: String,
    last_delay_ms: i32,
    last_traffic_at_ms: u128,
    last_upload_total: u64,
    last_download_total: u64,
    dns_config: ClashDnsConfig,
    runtime_config: RuntimeConfig,
    connection_mode: ConnectionMode,
}

static STATE: OnceLock<Mutex<CoreState>> = OnceLock::new();
static GEOSITE_DATA: OnceLock<Result<BTreeMap<String, GeositeCategory>, String>> = OnceLock::new();
const GEOSITE_DAT_Z: &[u8] = include_bytes!("../assets/geosite.dat.z");

fn state() -> &'static Mutex<CoreState> {
    STATE.get_or_init(|| Mutex::new(CoreState::default()))
}

#[cfg(feature = "shoes-backend")]
struct ShoesHandle {
    runtime: tokio::runtime::Runtime,
    shutdown_tx: Option<oneshot::Sender<()>>,
    running: Arc<AtomicBool>,
}

#[cfg(feature = "shoes-backend")]
static SHOES_HANDLE: OnceLock<Mutex<Option<ShoesHandle>>> = OnceLock::new();

#[cfg(feature = "shoes-backend")]
fn shoes_handle() -> &'static Mutex<Option<ShoesHandle>> {
    SHOES_HANDLE.get_or_init(|| Mutex::new(None))
}

fn cstr_to_string(value: *const c_char) -> Result<String, i32> {
    if value.is_null() {
        return Err(-1);
    }
    let text = unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| -2)?
        .to_string();
    Ok(text)
}

fn into_c_string(value: String) -> *mut c_char {
    match CString::new(value) {
        Ok(text) => text.into_raw(),
        Err(_) => CString::new("{}").unwrap().into_raw(),
    }
}

fn trim_quote(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.len() >= 2 {
        let first = trimmed.as_bytes()[0] as char;
        let last = trimmed.as_bytes()[trimmed.len() - 1] as char;
        if (first == '\'' && last == '\'') || (first == '"' && last == '"') {
            return trimmed[1..trimmed.len() - 1].to_string();
        }
    }
    trimmed.to_string()
}

fn flow_value(line: &str, key: &str) -> String {
    let markers = [
        format!("{key}:"),
        format!("{key} :"),
        format!("\"{key}\":"),
        format!("\"{key}\" :"),
        format!("'{key}':"),
        format!("'{key}' :"),
    ];
    let Some((start, marker_len)) = markers
        .iter()
        .filter_map(|marker| line.find(marker).map(|start| (start, marker.len())))
        .min_by_key(|(start, _)| *start)
    else {
        return String::new();
    };
    let mut quote = '\0';
    let mut value = String::new();
    let mut square_depth = 0usize;
    let mut curly_depth = 0usize;
    for ch in line[start + marker_len..].trim_start().chars() {
        if (ch == '\'' || ch == '"') && quote == '\0' {
            quote = ch;
            continue;
        }
        if quote != '\0' && ch == quote {
            quote = '\0';
            continue;
        }
        if quote == '\0' {
            match ch {
                '[' => square_depth += 1,
                ']' => square_depth = square_depth.saturating_sub(1),
                '{' => curly_depth += 1,
                '}' => {
                    if square_depth == 0 && curly_depth == 0 {
                        break;
                    }
                    curly_depth = curly_depth.saturating_sub(1);
                }
                ',' if square_depth == 0 && curly_depth == 0 => break,
                _ => {}
            }
        }
        value.push(ch);
    }
    trim_quote(&value)
}

fn flow_objects(value: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut quote = '\0';
    let mut depth = 0usize;
    let mut current = String::new();
    for ch in value.chars() {
        if (ch == '\'' || ch == '"') && quote == '\0' {
            quote = ch;
        } else if quote != '\0' && ch == quote {
            quote = '\0';
        }
        if quote == '\0' && ch == '{' {
            if depth == 0 {
                current.clear();
            }
            depth += 1;
        }
        if depth > 0 {
            current.push(ch);
        }
        if quote == '\0' && ch == '}' && depth > 0 {
            depth -= 1;
            if depth == 0 {
                out.push(current.clone());
                current.clear();
            }
        }
    }
    out
}

fn flow_list(value: &str) -> Vec<String> {
    value
        .trim()
        .trim_start_matches('[')
        .trim_end_matches(']')
        .split(',')
        .map(trim_quote)
        .filter(|name| !name.is_empty())
        .collect::<Vec<String>>()
}

fn proxy_from_flow(line: &str) -> Option<ProxyNode> {
    let name = flow_value(line, "name");
    if name.is_empty() {
        return None;
    }
    let mut proxy = ProxyNode {
        name,
        proxy_type: flow_value(line, "type"),
        fields: BTreeMap::new(),
    };
    for key in [
        "name",
        "type",
        "server",
        "port",
        "cipher",
        "password",
        "auth",
        "auth-str",
        "auth_str",
        "token",
        "username",
        "uuid",
        "sni",
        "servername",
        "tls",
        "network",
        "path",
        "host",
        "Host",
        "security",
        "skip-cert-verify",
        "fingerprint",
        "client-fingerprint",
        "alpn",
        "pbk",
        "public-key",
        "sid",
        "short-id",
        "server-name",
        "server_name",
        "flow",
        "plugin",
        "shadow-tls-password",
        "shadowtls-password",
        "shadow-tls-sni",
        "shadowtls-sni",
        "obfs",
        "obfs-password",
        "obfs_password",
        "congestion-controller",
        "congestion_controller",
        "disable-sni",
        "disable_sni",
    ] {
        let value = flow_value(line, key);
        if !value.is_empty() {
            if key == "Host" {
                assign_proxy_field(&mut proxy, "ws-host", value);
            } else {
                assign_proxy_field_normalized(&mut proxy, key, value);
            }
        }
    }
    let ws_path = flow_value(line, "ws-opts.path");
    if !ws_path.is_empty() {
        assign_proxy_field(&mut proxy, "path", ws_path);
    }
    let ws_host = flow_value(line, "ws-opts.headers.Host");
    if !ws_host.is_empty() {
        assign_proxy_field(&mut proxy, "ws-host", ws_host);
    }
    let h2_path = flow_value(line, "h2-opts.path");
    if !h2_path.is_empty() {
        assign_proxy_field(&mut proxy, "h2-path", h2_path);
    }
    let h2_host = flow_value(line, "h2-opts.host");
    if !h2_host.is_empty() {
        assign_proxy_field(&mut proxy, "h2-host", h2_host);
    }
    for key in [
        "grpc-opts.serviceName",
        "grpc-opts.service-name",
        "grpc-opts.grpc-service-name",
    ] {
        let grpc_service_name = flow_value(line, key);
        if !grpc_service_name.is_empty() {
            assign_proxy_field(&mut proxy, "grpc-service-name", grpc_service_name);
            break;
        }
    }
    let reality_public_key = flow_value(line, "reality-opts.public-key");
    if !reality_public_key.is_empty() {
        assign_proxy_field(&mut proxy, "public-key", reality_public_key);
    }
    let reality_short_id = flow_value(line, "reality-opts.short-id");
    if !reality_short_id.is_empty() {
        assign_proxy_field(&mut proxy, "short-id", reality_short_id);
    }
    let plugin_mode = flow_value(line, "plugin-opts.mode");
    if !plugin_mode.is_empty() {
        assign_plugin_opt(&mut proxy, "mode", plugin_mode);
    }
    let plugin_path = flow_value(line, "plugin-opts.path");
    if !plugin_path.is_empty() {
        assign_plugin_opt(&mut proxy, "path", plugin_path);
    }
    let plugin_host = flow_value(line, "plugin-opts.host");
    if !plugin_host.is_empty() {
        assign_plugin_opt(&mut proxy, "host", plugin_host);
    }
    let plugin_tls = flow_value(line, "plugin-opts.tls");
    if !plugin_tls.is_empty() {
        assign_plugin_opt(&mut proxy, "tls", plugin_tls);
    }
    Some(proxy)
}

fn group_from_flow(line: &str) -> Option<ProxyGroup> {
    let name = flow_value(line, "name");
    if name.is_empty() {
        return None;
    }
    let mut names = flow_list(&flow_value(line, "proxies"));
    if names.is_empty() {
        names = flow_list(&flow_value(line, "use"));
    }
    let now = names.first().cloned().unwrap_or_default();
    Some(ProxyGroup {
        name,
        group_type: flow_value(line, "type"),
        now,
        all: names,
    })
}

fn section_sample(config: &str, section_name: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut in_section = false;
    for raw_line in config.lines() {
        let trimmed = raw_line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let top_level =
            !raw_line.starts_with(' ') && !raw_line.starts_with('\t') && !raw_line.starts_with('-');
        if top_level {
            if in_section {
                break;
            }
            if trimmed.starts_with(section_name) {
                in_section = true;
                out.push(trimmed.to_string());
            }
            continue;
        }
        if in_section {
            out.push(trimmed.to_string());
            if out.len() >= 8 {
                break;
            }
        }
    }
    out.join(" | ")
}

fn assign_proxy_field(proxy: &mut ProxyNode, key: &str, value: String) {
    if key == "name" {
        proxy.name = value.clone();
    } else if key == "type" {
        proxy.proxy_type = value.clone();
    }
    proxy.fields.insert(key.to_string(), value);
}

fn assign_proxy_field_normalized(proxy: &mut ProxyNode, key: &str, value: String) {
    match key {
        "auth" | "auth-str" | "auth_str" => assign_proxy_field(proxy, "password", value),
        "token" => assign_proxy_field(proxy, "password", value),
        "obfs-password" | "obfs_password" => assign_proxy_field(proxy, "obfs-password", value),
        "congestion-controller" | "congestion_controller" => {
            assign_proxy_field(proxy, "congestion-controller", value)
        }
        "disable-sni" | "disable_sni" => assign_proxy_field(proxy, "disable-sni", value),
        _ => assign_proxy_field(proxy, key, value),
    }
}

fn block_key_value(line: &str) -> Option<(String, String)> {
    let split = line.find(':')?;
    let key = trim_quote(line[..split].trim());
    if key.is_empty() {
        return None;
    }
    let value = trim_quote(&line[split + 1..]);
    Some((key.to_string(), value))
}

fn leading_indent(line: &str) -> usize {
    line.chars()
        .take_while(|ch| *ch == ' ' || *ch == '\t')
        .map(|ch| if ch == '\t' { 2 } else { 1 })
        .sum()
}

fn assign_plugin_opt(proxy: &mut ProxyNode, key: &str, value: String) {
    let plugin = proxy_field(proxy, "plugin").to_lowercase();
    if plugin == "shadow-tls" || plugin == "shadowtls" {
        match key {
            "password" => assign_proxy_field(proxy, "shadow-tls-password", value),
            "host" | "sni" | "servername" => assign_proxy_field(proxy, "shadow-tls-sni", value),
            _ => {
                proxy.fields.insert(format!("plugin-{key}"), value);
            }
        }
    } else if plugin == "v2ray-plugin" || plugin == "v2ray_plugin" {
        match key {
            "mode" => assign_proxy_field(proxy, "plugin-mode", value),
            "path" => assign_proxy_field(proxy, "path", value),
            "host" | "Host" => assign_proxy_field(proxy, "ws-host", value),
            "tls" => assign_proxy_field(proxy, "plugin-tls", value),
            _ => {
                proxy.fields.insert(format!("plugin-{key}"), value);
            }
        }
    } else {
        proxy.fields.insert(format!("plugin-{key}"), value);
    }
}

fn assign_ws_opt(proxy: &mut ProxyNode, key: &str, value: String) {
    match key {
        "path" => assign_proxy_field(proxy, "path", value),
        "host" | "Host" => assign_proxy_field(proxy, "ws-host", value),
        _ => {
            proxy.fields.insert(format!("ws-{key}"), value);
        }
    }
}

fn assign_reality_opt(proxy: &mut ProxyNode, key: &str, value: String) {
    match key {
        "public-key" | "public_key" | "pbk" => assign_proxy_field(proxy, "public-key", value),
        "short-id" | "short_id" | "sid" => assign_proxy_field(proxy, "short-id", value),
        "server-name" | "server_name" | "sni" | "servername" => {
            assign_proxy_field(proxy, "sni", value)
        }
        _ => {
            proxy.fields.insert(format!("reality-{key}"), value);
        }
    }
}

fn assign_tls_opt(proxy: &mut ProxyNode, key: &str, value: String) {
    match key {
        "sni" | "servername" | "server-name" | "server_name" => {
            assign_proxy_field(proxy, "sni", value)
        }
        "client-fingerprint" => assign_proxy_field(proxy, "client-fingerprint", value),
        "fingerprint" => assign_proxy_field(proxy, "client-fingerprint", value),
        "server-fingerprint" => assign_proxy_field(proxy, "server-fingerprint", value),
        "alpn" | "alpn-protocols" | "alpn_protocols" => assign_proxy_field(proxy, "alpn", value),
        _ => {
            proxy.fields.insert(format!("tls-{key}"), value);
        }
    }
}

fn assign_h2mux_opt(proxy: &mut ProxyNode, key: &str, value: String) {
    match key {
        "enabled" | "enable" => assign_proxy_field(proxy, "h2mux-enabled", value),
        "max-connections" | "max_connections" => {
            assign_proxy_field(proxy, "h2mux-max-connections", value)
        }
        "min-streams" | "min_streams" => assign_proxy_field(proxy, "h2mux-min-streams", value),
        "max-streams" | "max_streams" => assign_proxy_field(proxy, "h2mux-max-streams", value),
        "padding" => assign_proxy_field(proxy, "h2mux-padding", value),
        _ => {
            proxy.fields.insert(format!("h2mux-{key}"), value);
        }
    }
}

fn assign_h2_transport_opt(proxy: &mut ProxyNode, key: &str, value: String) {
    match key {
        "path" => assign_proxy_field(proxy, "h2-path", value),
        "host" | "Host" => assign_proxy_field(proxy, "h2-host", value),
        _ => {
            proxy.fields.insert(format!("h2-{key}"), value);
        }
    }
}

fn assign_grpc_transport_opt(proxy: &mut ProxyNode, key: &str, value: String) {
    match key {
        "serviceName" | "service-name" | "grpc-service-name" | "service_name" => {
            assign_proxy_field(proxy, "grpc-service-name", value)
        }
        "authority" | "host" | "Host" => assign_proxy_field(proxy, "grpc-authority", value),
        _ => {
            proxy.fields.insert(format!("grpc-{key}"), value);
        }
    }
}

fn assign_proxy_nested_field(proxy: &mut ProxyNode, section: &str, key: &str, value: String) {
    match section {
        "plugin-opts" => assign_plugin_opt(proxy, key, value),
        "ws-opts" | "ws-headers" => assign_ws_opt(proxy, key, value),
        "h2-opts" | "http2-opts" => assign_h2_transport_opt(proxy, key, value),
        "grpc-opts" => assign_grpc_transport_opt(proxy, key, value),
        "reality-opts" => assign_reality_opt(proxy, key, value),
        "tls-opts" => assign_tls_opt(proxy, key, value),
        "h2mux" | "mux" | "smux" => assign_h2mux_opt(proxy, key, value),
        _ => assign_proxy_field(proxy, key, value),
    }
}

fn yaml_mapping_get<'a>(
    mapping: &'a serde_yaml::Mapping,
    key: &str,
) -> Option<&'a serde_yaml::Value> {
    mapping.get(serde_yaml::Value::String(key.to_string()))
}

fn yaml_value_to_string(value: &serde_yaml::Value) -> String {
    match value {
        serde_yaml::Value::Null => String::new(),
        serde_yaml::Value::Bool(value) => value.to_string(),
        serde_yaml::Value::Number(value) => value.to_string(),
        serde_yaml::Value::String(value) => trim_quote(value),
        serde_yaml::Value::Sequence(values) => values
            .iter()
            .map(yaml_value_to_string)
            .filter(|value| !value.is_empty())
            .collect::<Vec<String>>()
            .join(","),
        _ => String::new(),
    }
}

fn yaml_sequence_strings(value: Option<&serde_yaml::Value>) -> Vec<String> {
    match value {
        Some(serde_yaml::Value::Sequence(values)) => values
            .iter()
            .map(yaml_value_to_string)
            .filter(|value| !value.is_empty())
            .collect(),
        Some(value) => {
            let value = yaml_value_to_string(value);
            if value.is_empty() {
                Vec::new()
            } else {
                vec![value]
            }
        }
        None => Vec::new(),
    }
}

fn assign_proxy_yaml_nested(proxy: &mut ProxyNode, section: &str, mapping: &serde_yaml::Mapping) {
    for (raw_key, raw_value) in mapping {
        let key = yaml_value_to_string(raw_key);
        if key.is_empty() {
            continue;
        }
        if section == "ws-opts" && key == "headers" {
            if let serde_yaml::Value::Mapping(headers) = raw_value {
                for (header_key, header_value) in headers {
                    let header_key = yaml_value_to_string(header_key);
                    if header_key.eq_ignore_ascii_case("host") {
                        assign_ws_opt(proxy, "host", yaml_value_to_string(header_value));
                    }
                }
            }
            continue;
        }
        assign_proxy_nested_field(proxy, section, &key, yaml_value_to_string(raw_value));
    }
}

fn proxy_from_yaml(value: &serde_yaml::Value) -> Option<ProxyNode> {
    let serde_yaml::Value::Mapping(mapping) = value else {
        return None;
    };
    let name = yaml_value_to_string(yaml_mapping_get(mapping, "name")?);
    if name.is_empty() {
        return None;
    }
    let mut proxy = ProxyNode {
        name,
        proxy_type: yaml_mapping_get(mapping, "type")
            .map(yaml_value_to_string)
            .unwrap_or_default(),
        fields: BTreeMap::new(),
    };
    let direct_keys = [
        "name",
        "type",
        "server",
        "port",
        "cipher",
        "password",
        "auth",
        "auth-str",
        "auth_str",
        "token",
        "username",
        "uuid",
        "sni",
        "servername",
        "tls",
        "network",
        "path",
        "host",
        "Host",
        "security",
        "skip-cert-verify",
        "fingerprint",
        "client-fingerprint",
        "alpn",
        "pbk",
        "public-key",
        "sid",
        "short-id",
        "server-name",
        "server_name",
        "flow",
        "udp",
        "mux",
        "h2mux",
        "smux",
        "h2mux-enabled",
        "h2mux-max-connections",
        "h2mux-min-streams",
        "h2mux-max-streams",
        "h2mux-padding",
        "h2-path",
        "h2-host",
        "grpc-service-name",
        "grpc-authority",
        "plugin",
        "shadow-tls-password",
        "shadowtls-password",
        "shadow-tls-sni",
        "shadowtls-sni",
        "obfs",
        "obfs-password",
        "obfs_password",
        "congestion-controller",
        "congestion_controller",
        "disable-sni",
        "disable_sni",
    ];
    for key in direct_keys {
        if let Some(value) = yaml_mapping_get(mapping, key) {
            let value = yaml_value_to_string(value);
            if !value.is_empty() {
                if key == "Host" {
                    assign_proxy_field(&mut proxy, "ws-host", value);
                } else {
                    assign_proxy_field_normalized(&mut proxy, key, value);
                }
            }
        }
    }
    for section in [
        "plugin-opts",
        "ws-opts",
        "h2-opts",
        "http2-opts",
        "grpc-opts",
        "reality-opts",
        "tls-opts",
        "h2mux",
        "mux",
        "smux",
    ] {
        if let Some(serde_yaml::Value::Mapping(nested)) = yaml_mapping_get(mapping, section) {
            assign_proxy_yaml_nested(&mut proxy, section, nested);
        }
    }
    Some(proxy)
}

fn group_from_yaml(
    value: &serde_yaml::Value,
    provider_proxy_names: &BTreeMap<String, Vec<String>>,
) -> Option<ProxyGroup> {
    let serde_yaml::Value::Mapping(mapping) = value else {
        return None;
    };
    let name = yaml_value_to_string(yaml_mapping_get(mapping, "name")?);
    if name.is_empty() {
        return None;
    }
    let mut names = yaml_sequence_strings(yaml_mapping_get(mapping, "proxies"));
    let uses = yaml_sequence_strings(yaml_mapping_get(mapping, "use"));
    for provider_name in uses {
        if let Some(provider_names) = provider_proxy_names.get(&provider_name) {
            for proxy_name in provider_names {
                if !names.contains(proxy_name) {
                    names.push(proxy_name.clone());
                }
            }
        } else if names.is_empty() && !names.contains(&provider_name) {
            names.push(provider_name);
        }
    }
    let now = yaml_mapping_get(mapping, "now")
        .map(yaml_value_to_string)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| names.first().cloned().unwrap_or_default());
    Some(ProxyGroup {
        name,
        group_type: yaml_mapping_get(mapping, "type")
            .map(yaml_value_to_string)
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "select".to_string()),
        now,
        all: names,
    })
}

fn rule_provider_entries_from_yaml(value: &serde_yaml::Value) -> Vec<String> {
    if let serde_yaml::Value::Mapping(mapping) = value {
        for key in ["payload", "rules"] {
            let entries = yaml_sequence_strings(yaml_mapping_get(mapping, key));
            if !entries.is_empty() {
                return entries;
            }
        }
    }
    Vec::new()
}

fn rule_provider_behavior_from_yaml(value: &serde_yaml::Value) -> String {
    if let serde_yaml::Value::Mapping(mapping) = value {
        return yaml_mapping_get(mapping, "behavior")
            .map(yaml_value_to_string)
            .filter(|item| !item.is_empty())
            .unwrap_or_else(|| "classical".to_string())
            .to_ascii_lowercase();
    }
    "classical".to_string()
}

fn provider_rule_parts(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(trim_quote)
        .filter(|part| !part.is_empty())
        .collect()
}

fn supported_expanded_rule_type(rule_type: &str) -> bool {
    matches!(
        rule_type,
        "DOMAIN"
            | "DOMAIN-SUFFIX"
            | "DOMAIN-KEYWORD"
            | "IP-CIDR"
            | "IP-CIDR6"
            | "DST-PORT"
            | "GEOIP"
            | "GEOSITE"
    )
}

fn normalized_domain_provider_rule(value: &str, target: &str) -> Option<ClashRule> {
    let lower = value.to_ascii_lowercase();
    let (rule_type, raw_payload) = if lower.starts_with("domain:") {
        ("DOMAIN-SUFFIX", &value[7..])
    } else if lower.starts_with("full:") {
        ("DOMAIN", &value[5..])
    } else if lower.starts_with("keyword:") {
        ("DOMAIN-KEYWORD", &value[8..])
    } else {
        ("DOMAIN-SUFFIX", value)
    };
    let payload = raw_payload
        .trim()
        .trim_start_matches("+.")
        .trim_start_matches('.')
        .to_string();
    if payload.is_empty() {
        return None;
    }
    Some(ClashRule {
        rule_type: rule_type.to_string(),
        payload,
        target: target.to_string(),
    })
}

fn rule_from_provider_entry(entry: &str, behavior: &str, target: &str) -> Option<ClashRule> {
    let value = trim_quote(entry.trim());
    if value.is_empty() || value.starts_with('#') || target.is_empty() {
        return None;
    }
    let parts = provider_rule_parts(&value);
    if parts.len() >= 2 {
        let rule_type = parts[0].to_uppercase();
        if supported_expanded_rule_type(&rule_type) {
            return Some(ClashRule {
                rule_type,
                payload: parts[1].clone(),
                target: target.to_string(),
            });
        }
    }
    if behavior == "domain" {
        return normalized_domain_provider_rule(&value, target);
    }
    if behavior == "ipcidr" || behavior == "ip-cidr" {
        return Some(ClashRule {
            rule_type: if value.contains(':') {
                "IP-CIDR6".to_string()
            } else {
                "IP-CIDR".to_string()
            },
            payload: value,
            target: target.to_string(),
        });
    }
    let Some(rule) = parse_rule_line(&value) else {
        return None;
    };
    Some(ClashRule {
        target: target.to_string(),
        ..rule
    })
}

fn parse_clash_config_yaml(
    config: &str,
) -> Option<(Vec<ProxyNode>, Vec<ProxyGroup>, Vec<ClashRule>)> {
    let root = serde_yaml::from_str::<serde_yaml::Value>(config).ok()?;
    let serde_yaml::Value::Mapping(mapping) = root else {
        return None;
    };
    let mut proxies = Vec::new();
    let mut groups = Vec::new();
    let mut rules = Vec::new();
    let mut provider_proxy_names: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut rule_providers: BTreeMap<String, (String, Vec<String>)> = BTreeMap::new();

    if let Some(serde_yaml::Value::Sequence(items)) = yaml_mapping_get(&mapping, "proxies") {
        for item in items {
            if let Some(proxy) = proxy_from_yaml(item) {
                proxies.push(proxy);
            }
        }
    }
    if let Some(serde_yaml::Value::Mapping(providers)) =
        yaml_mapping_get(&mapping, "proxy-providers")
    {
        for (provider_key, provider) in providers {
            let provider_name = yaml_value_to_string(provider_key);
            let mut names = Vec::new();
            if let serde_yaml::Value::Mapping(provider_map) = provider {
                if let Some(serde_yaml::Value::Sequence(items)) =
                    yaml_mapping_get(provider_map, "proxies")
                {
                    for item in items {
                        if let Some(proxy) = proxy_from_yaml(item) {
                            names.push(proxy.name.clone());
                            proxies.push(proxy);
                        }
                    }
                }
            }
            if !provider_name.is_empty() && !names.is_empty() {
                provider_proxy_names.insert(provider_name, names);
            }
        }
    }
    if let Some(serde_yaml::Value::Mapping(providers)) =
        yaml_mapping_get(&mapping, "rule-providers")
    {
        for (provider_key, provider) in providers {
            let provider_name = yaml_value_to_string(provider_key);
            if provider_name.is_empty() {
                continue;
            }
            let behavior = rule_provider_behavior_from_yaml(provider);
            let entries = rule_provider_entries_from_yaml(provider);
            if !entries.is_empty() {
                rule_providers.insert(provider_name, (behavior, entries));
            }
        }
    }
    if let Some(serde_yaml::Value::Sequence(items)) = yaml_mapping_get(&mapping, "proxy-groups") {
        for item in items {
            if let Some(group) = group_from_yaml(item, &provider_proxy_names) {
                groups.push(group);
            }
        }
    }
    if let Some(serde_yaml::Value::Sequence(items)) = yaml_mapping_get(&mapping, "rules") {
        for item in items {
            let line = yaml_value_to_string(item);
            if let Some(rule) = parse_rule_line(&line) {
                if rule.rule_type == "RULE-SET" {
                    if let Some((behavior, entries)) = rule_providers.get(&rule.payload) {
                        for entry in entries {
                            if let Some(expanded_rule) =
                                rule_from_provider_entry(entry, behavior, &rule.target)
                            {
                                rules.push(expanded_rule);
                            }
                        }
                    } else {
                        rules.push(rule);
                    }
                } else {
                    rules.push(rule);
                }
            }
        }
    }

    sanitize_parsed_config(&mut proxies, &mut groups);
    Some((proxies, groups, rules))
}

fn parse_clash_config_fallback(config: &str) -> (Vec<ProxyNode>, Vec<ProxyGroup>, Vec<ClashRule>) {
    let mut proxies: Vec<ProxyNode> = Vec::new();
    let mut groups: Vec<ProxyGroup> = Vec::new();
    let mut rules: Vec<ClashRule> = Vec::new();
    let mut section = String::new();
    let mut current_proxy: Option<ProxyNode> = None;
    let mut current_group: Option<ProxyGroup> = None;
    let mut reading_group_proxies = false;
    let mut proxy_nested_section = String::new();
    let mut proxy_nested_indent = 0usize;

    for raw_line in config.lines() {
        let trimmed = raw_line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        let top_level =
            !raw_line.starts_with(' ') && !raw_line.starts_with('\t') && !raw_line.starts_with('-');
        if top_level {
            if let Some(proxy) = current_proxy.take() {
                if !proxy.name.is_empty() {
                    proxies.push(proxy);
                }
            }
            if let Some(group) = current_group.take() {
                if !group.name.is_empty() {
                    groups.push(group);
                }
            }
            reading_group_proxies = false;
            proxy_nested_section.clear();
            section = if trimmed.starts_with("proxies:") {
                if let Some((_, inline_value)) = trimmed.split_once(':') {
                    for item in flow_objects(inline_value) {
                        if let Some(proxy) = proxy_from_flow(&item) {
                            proxies.push(proxy);
                        }
                    }
                }
                "proxies".to_string()
            } else if trimmed.starts_with("proxy-groups:") {
                if let Some((_, inline_value)) = trimmed.split_once(':') {
                    for item in flow_objects(inline_value) {
                        if let Some(group) = group_from_flow(&item) {
                            groups.push(group);
                        }
                    }
                }
                "proxy-groups".to_string()
            } else if trimmed.starts_with("rules:") {
                "rules".to_string()
            } else {
                String::new()
            };
            continue;
        }

        if section == "proxies" {
            if trimmed.starts_with("- {") {
                proxy_nested_section.clear();
                if let Some(proxy) = proxy_from_flow(trimmed) {
                    proxies.push(proxy);
                }
                current_proxy = None;
            } else if trimmed == "-" {
                proxy_nested_section.clear();
                if let Some(proxy) = current_proxy.take() {
                    if !proxy.name.is_empty() {
                        proxies.push(proxy);
                    }
                }
                current_proxy = Some(ProxyNode {
                    name: String::new(),
                    proxy_type: String::new(),
                    fields: BTreeMap::new(),
                });
            } else if let Some(rest) = trimmed.strip_prefix("- name:") {
                proxy_nested_section.clear();
                if let Some(proxy) = current_proxy.take() {
                    if !proxy.name.is_empty() {
                        proxies.push(proxy);
                    }
                }
                current_proxy = Some(ProxyNode {
                    name: trim_quote(rest),
                    proxy_type: String::new(),
                    fields: BTreeMap::new(),
                });
            } else if let Some(proxy) = current_proxy.as_mut() {
                let indent = leading_indent(raw_line);
                if !proxy_nested_section.is_empty() && indent <= proxy_nested_indent {
                    proxy_nested_section.clear();
                }
                if matches!(
                    trimmed,
                    "plugin-opts:"
                        | "ws-opts:"
                        | "h2-opts:"
                        | "http2-opts:"
                        | "grpc-opts:"
                        | "headers:"
                        | "reality-opts:"
                        | "tls-opts:"
                ) {
                    if trimmed == "headers:" && proxy_nested_section != "ws-opts" {
                        continue;
                    }
                    proxy_nested_section = if trimmed == "headers:" {
                        "ws-headers".to_string()
                    } else {
                        trimmed.trim_end_matches(':').to_string()
                    };
                    proxy_nested_indent = indent;
                    continue;
                }
                if let Some((key, value)) = block_key_value(trimmed) {
                    if !proxy_nested_section.is_empty() {
                        assign_proxy_nested_field(proxy, &proxy_nested_section, &key, value);
                    } else {
                        assign_proxy_field_normalized(proxy, &key, value);
                    }
                }
            }
        } else if section == "proxy-groups" {
            if trimmed.starts_with("- {") {
                if let Some(group) = current_group.take() {
                    if !group.name.is_empty() {
                        groups.push(group);
                    }
                }
                current_group = group_from_flow(trimmed);
                reading_group_proxies = false;
            } else if trimmed == "-" {
                if let Some(group) = current_group.take() {
                    if !group.name.is_empty() {
                        groups.push(group);
                    }
                }
                current_group = Some(ProxyGroup {
                    name: String::new(),
                    group_type: "select".to_string(),
                    now: String::new(),
                    all: Vec::new(),
                });
                reading_group_proxies = false;
            } else if let Some(rest) = trimmed.strip_prefix("- name:") {
                if let Some(group) = current_group.take() {
                    if !group.name.is_empty() {
                        groups.push(group);
                    }
                }
                current_group = Some(ProxyGroup {
                    name: trim_quote(rest),
                    group_type: "select".to_string(),
                    now: String::new(),
                    all: Vec::new(),
                });
                reading_group_proxies = false;
            } else if let Some(group) = current_group.as_mut() {
                if let Some(rest) = trimmed.strip_prefix("name:") {
                    group.name = trim_quote(rest);
                } else if let Some(rest) = trimmed.strip_prefix("type:") {
                    group.group_type = trim_quote(rest);
                } else if trimmed == "proxies:" {
                    reading_group_proxies = true;
                } else if trimmed == "use:" {
                    reading_group_proxies = true;
                } else if reading_group_proxies {
                    if let Some(rest) = trimmed.strip_prefix("- ") {
                        let name = trim_quote(rest);
                        if group.now.is_empty() {
                            group.now = name.clone();
                        }
                        group.all.push(name);
                    }
                } else if trimmed.contains(':') {
                    reading_group_proxies = false;
                }
            }
        } else if section == "rules" {
            if let Some(rest) = trimmed.strip_prefix("- ") {
                if let Some(rule) = parse_rule_line(rest) {
                    rules.push(rule);
                }
            }
        }
    }

    if let Some(proxy) = current_proxy {
        if !proxy.name.is_empty() {
            proxies.push(proxy);
        }
    }
    if let Some(group) = current_group {
        if !group.name.is_empty() {
            groups.push(group);
        }
    }

    sanitize_parsed_config(&mut proxies, &mut groups);

    (proxies, groups, rules)
}

fn parse_clash_config(config: &str) -> (Vec<ProxyNode>, Vec<ProxyGroup>, Vec<ClashRule>) {
    if let Some(parsed) = parse_clash_config_yaml(config) {
        if !parsed.0.is_empty() || !parsed.1.is_empty() || !parsed.2.is_empty() {
            return parsed;
        }
    }
    parse_clash_config_fallback(config)
}

fn parse_clash_dns_config(config: &str) -> ClashDnsConfig {
    let root = match serde_yaml::from_str::<serde_yaml::Value>(config) {
        Ok(root) => root,
        Err(_) => return ClashDnsConfig::default(),
    };
    let serde_yaml::Value::Mapping(ref mapping) = root else {
        return ClashDnsConfig::default();
    };
    let Some(serde_yaml::Value::Mapping(dns_section)) = yaml_mapping_get(mapping, "dns") else {
        return ClashDnsConfig::default();
    };

    let enabled = yaml_mapping_get(dns_section, "enable")
        .or_else(|| yaml_mapping_get(dns_section, "enabled"))
        .map(yaml_value_to_string)
        .map(|v| truthy(&v))
        .unwrap_or(false);

    let ipv6 = yaml_mapping_get(dns_section, "ipv6")
        .map(yaml_value_to_string)
        .map(|v| truthy(&v))
        .unwrap_or(false);

    let enhanced_mode = yaml_mapping_get(dns_section, "enhanced-mode")
        .map(yaml_value_to_string)
        .unwrap_or_else(|| "fake-ip".to_string());

    let fake_ip_range = yaml_mapping_get(dns_section, "fake-ip-range")
        .map(yaml_value_to_string)
        .unwrap_or_else(|| "198.18.0.0/16".to_string());

    let nameservers = yaml_sequence_strings(yaml_mapping_get(dns_section, "nameserver"));
    let default_nameservers =
        yaml_sequence_strings(yaml_mapping_get(dns_section, "default-nameserver"));
    let fake_ip_filter = yaml_sequence_strings(yaml_mapping_get(dns_section, "fake-ip-filter"));

    ClashDnsConfig {
        enabled,
        ipv6,
        enhanced_mode,
        fake_ip_range,
        nameservers,
        default_nameservers,
        fake_ip_filter,
    }
}

fn parse_runtime_config(config: &str) -> RuntimeConfig {
    let root = match serde_yaml::from_str::<serde_yaml::Value>(config) {
        Ok(root) => root,
        Err(_) => return RuntimeConfig::default(),
    };
    let serde_yaml::Value::Mapping(ref mapping) = root else {
        return RuntimeConfig::default();
    };
    let Some(serde_yaml::Value::Mapping(runtime_section)) =
        yaml_mapping_get(mapping, "clashhm").or_else(|| yaml_mapping_get(mapping, "clash-hm"))
    else {
        return RuntimeConfig::default();
    };
    let tls_mode = yaml_mapping_get(runtime_section, "tls-client")
        .or_else(|| yaml_mapping_get(runtime_section, "tls-client-mode"))
        .or_else(|| yaml_mapping_get(runtime_section, "tls-engine"))
        .map(yaml_value_to_string)
        .unwrap_or_else(|| "chrome".to_string());
    RuntimeConfig {
        tls_client_mode: if tls_mode.eq_ignore_ascii_case("rustls") {
            TlsClientMode::Rustls
        } else {
            TlsClientMode::Chrome
        },
    }
}

fn parse_connection_mode(config: &str) -> ConnectionMode {
    let root = match serde_yaml::from_str::<serde_yaml::Value>(config) {
        Ok(root) => root,
        Err(_) => return ConnectionMode::Rule,
    };
    let serde_yaml::Value::Mapping(ref mapping) = root else {
        return ConnectionMode::Rule;
    };
    yaml_mapping_get(mapping, "mode")
        .map(yaml_value_to_string)
        .map(|mode| parse_connection_mode_text(&mode))
        .unwrap_or(ConnectionMode::Rule)
}

fn parse_connection_mode_text(mode: &str) -> ConnectionMode {
    if mode.eq_ignore_ascii_case("global") {
        ConnectionMode::Global
    } else if mode.eq_ignore_ascii_case("direct") {
        ConnectionMode::Direct
    } else {
        ConnectionMode::Rule
    }
}

fn parse_rule_line(line: &str) -> Option<ClashRule> {
    let mut parts = line
        .split(',')
        .map(trim_quote)
        .filter(|part| !part.is_empty())
        .collect::<Vec<String>>();
    if parts.is_empty() {
        return None;
    }
    let rule_type = parts.remove(0).to_uppercase();
    if rule_type == "MATCH" {
        return parts.first().map(|target| ClashRule {
            rule_type,
            payload: String::new(),
            target: target.clone(),
        });
    }
    if parts.len() < 2 {
        return None;
    }
    Some(ClashRule {
        rule_type,
        payload: parts[0].clone(),
        target: parts[1].clone(),
    })
}

fn json_escape(value: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ => out.push(ch),
        }
    }
    out
}

fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis())
        .unwrap_or(0)
}

fn yaml_quote(value: &str) -> String {
    format!("\"{}\"", json_escape(value))
}

fn proxy_field<'a>(proxy: &'a ProxyNode, key: &str) -> &'a str {
    proxy.fields.get(key).map(String::as_str).unwrap_or("")
}

fn proxy_field_any<'a>(proxy: &'a ProxyNode, keys: &[&str]) -> &'a str {
    for key in keys {
        let value = proxy_field(proxy, key);
        if !value.is_empty() {
            return value;
        }
    }
    ""
}

fn is_metadata_proxy_name(name: &str) -> bool {
    name.contains("套餐到期")
        || name.contains("套餐重置")
        || name.contains("订阅获取")
        || name.contains("剩余流量")
        || name.contains("过期时间")
        || name.contains("官网")
        || name.contains("流量")
}

fn sanitize_parsed_config(proxies: &mut Vec<ProxyNode>, groups: &mut Vec<ProxyGroup>) {
    proxies.retain(|proxy| !is_metadata_proxy_name(&proxy.name));
    let proxy_names = proxies
        .iter()
        .map(|proxy| proxy.name.clone())
        .collect::<Vec<String>>();
    let group_names = groups
        .iter()
        .map(|group| group.name.clone())
        .collect::<Vec<String>>();

    for group in groups.iter_mut() {
        group.all.retain(|name| {
            name.eq_ignore_ascii_case("DIRECT")
                || name.eq_ignore_ascii_case("REJECT")
                || name.eq_ignore_ascii_case("REJECT-DROP")
                || proxy_names.iter().any(|proxy_name| proxy_name == name)
                || group_names.iter().any(|group_name| group_name == name)
        });
        if group.now.is_empty()
            || is_metadata_proxy_name(&group.now)
            || !group.all.iter().any(|name| name == &group.now)
        {
            group.now = group.all.first().cloned().unwrap_or_default();
        }
    }
    groups.retain(|group| !group.name.is_empty() && !group.all.is_empty());
}

fn truthy(value: &str) -> bool {
    let lower = value.to_lowercase();
    lower == "true" || lower == "1" || lower == "yes"
}

fn falsy(value: &str) -> bool {
    let lower = value.to_lowercase();
    lower == "false" || lower == "0" || lower == "no"
}

fn proxy_udp_enabled(proxy: &ProxyNode) -> bool {
    let udp = proxy_field(proxy, "udp");
    udp.is_empty() || truthy(udp)
}

fn h2mux_enabled(proxy: &ProxyNode) -> bool {
    let h2mux = proxy_field(proxy, "h2mux");
    let smux = proxy_field(proxy, "smux");
    let mux = proxy_field(proxy, "mux");
    let enabled = proxy_field_any(proxy, &["h2mux-enabled", "mux-enabled", "smux-enabled"]);
    truthy(h2mux) || truthy(smux) || truthy(mux) || truthy(enabled)
}

fn append_h2mux_yaml(proxy: &ProxyNode, out: &mut String, pad: &str) {
    if !h2mux_enabled(proxy) {
        return;
    }
    out.push_str(&format!("{pad}h2mux:\n"));
    let max_connections = proxy_field(proxy, "h2mux-max-connections");
    let min_streams = proxy_field(proxy, "h2mux-min-streams");
    let max_streams = proxy_field(proxy, "h2mux-max-streams");
    let padding = proxy_field(proxy, "h2mux-padding");
    if !max_connections.is_empty() {
        out.push_str(&format!("{pad}  max_connections: {max_connections}\n"));
    }
    if !min_streams.is_empty() {
        out.push_str(&format!("{pad}  min_streams: {min_streams}\n"));
    }
    if !max_streams.is_empty() {
        out.push_str(&format!("{pad}  max_streams: {max_streams}\n"));
    }
    if !padding.is_empty() {
        out.push_str(&format!(
            "{pad}  padding: {}\n",
            if truthy(padding) { "true" } else { "false" }
        ));
    }
}

fn selected_proxy<'a>(groups: &'a [ProxyGroup], proxies: &'a [ProxyNode]) -> Option<&'a ProxyNode> {
    let mut selected_name = String::new();
    for group in groups {
        if group.name.eq_ignore_ascii_case("proxy")
            || group.name.eq_ignore_ascii_case("global")
            || group.name.contains("节点")
            || group.name.contains("选择")
            || group.name.to_lowercase().contains("select")
        {
            selected_name = if group.now.is_empty() {
                group.all.first().cloned().unwrap_or_default()
            } else {
                group.now.clone()
            };
            break;
        }
    }
    if selected_name.is_empty() {
        for group in groups {
            selected_name = if group.now.is_empty() {
                group.all.first().cloned().unwrap_or_default()
            } else {
                group.now.clone()
            };
            if !selected_name.is_empty() {
                break;
            }
        }
    }
    proxies.iter().find(|proxy| proxy.name == selected_name)
}

fn selected_group<'a>(groups: &'a [ProxyGroup]) -> Option<&'a ProxyGroup> {
    for group in groups {
        if group.name.eq_ignore_ascii_case("proxy")
            || group.name.eq_ignore_ascii_case("global")
            || group.name.contains("节点")
            || group.name.contains("选择")
            || group.name.to_lowercase().contains("select")
        {
            return Some(group);
        }
    }
    groups
        .iter()
        .find(|group| !group.now.is_empty() || !group.all.is_empty())
}

fn selected_target_for_group<'a>(group_name: &str, groups: &'a [ProxyGroup]) -> Option<&'a str> {
    let group = groups.iter().find(|item| item.name == group_name)?;
    if group.now.is_empty() {
        group.all.first().map(String::as_str)
    } else {
        Some(group.now.as_str())
    }
}

fn best_url_test_target<'a>(
    group: &'a ProxyGroup,
    delay_by_proxy: &BTreeMap<String, i32>,
) -> Option<&'a str> {
    group
        .all
        .iter()
        .filter_map(|name| {
            let delay = *delay_by_proxy.get(name)?;
            if delay > 0 {
                Some((name.as_str(), delay))
            } else {
                None
            }
        })
        .min_by_key(|(_, delay)| *delay)
        .map(|(name, _)| name)
}

fn best_fallback_target<'a>(
    group: &'a ProxyGroup,
    delay_by_proxy: &BTreeMap<String, i32>,
) -> Option<&'a str> {
    group
        .all
        .iter()
        .find(|name| delay_by_proxy.get(*name).copied().unwrap_or(-1) > 0)
        .map(String::as_str)
}

fn update_auto_group_selection(groups: &mut [ProxyGroup], delay_by_proxy: &BTreeMap<String, i32>) {
    for group in groups {
        let group_type = group.group_type.to_ascii_lowercase();
        let selected = if group_type == "url-test" {
            best_url_test_target(group, delay_by_proxy)
        } else if group_type == "fallback" {
            best_fallback_target(group, delay_by_proxy)
        } else {
            None
        }
        .map(str::to_string);
        if let Some(selected) = selected {
            group.now = selected;
        }
    }
}

fn protocol_indent(indent: usize) -> String {
    " ".repeat(indent)
}

fn build_base_protocol(proxy: &ProxyNode, indent: usize) -> Result<String, String> {
    let proxy_type = proxy.proxy_type.to_lowercase();
    let pad = protocol_indent(indent);
    if proxy_type == "hysteria2" || proxy_type == "hy2" || proxy_type == "hysteria" {
        let password = proxy_field(proxy, "password");
        if password.is_empty() {
            return Err(format!("hysteria2 proxy {} missing password", proxy.name));
        }
        let obfs = proxy_field(proxy, "obfs");
        let obfs_password = proxy_field(proxy, "obfs-password");
        if !obfs.is_empty() || !obfs_password.is_empty() {
            return Err(format!(
                "hysteria2 proxy {} uses obfs, which is not supported by the embedded HY2 adapter yet",
                proxy.name
            ));
        }
        if truthy(proxy_field(proxy, "disable-sni")) {
            return Err(format!(
                "hysteria2 proxy {} uses disable-sni, which is not supported by the embedded HY2 adapter yet",
                proxy.name
            ));
        }
        return Ok(format!(
            "{pad}type: hysteria2\n{pad}password: {}\n{pad}udp_enabled: {}\n",
            yaml_quote(password),
            if proxy_udp_enabled(proxy) {
                "true"
            } else {
                "false"
            }
        ));
    }
    if proxy_type == "tuic" || proxy_type == "tuic-v5" || proxy_type == "tuicv5" {
        let uuid = proxy_field(proxy, "uuid");
        let password = proxy_field(proxy, "password");
        if uuid.is_empty() || password.is_empty() {
            return Err(format!("tuic proxy {} missing uuid/password", proxy.name));
        }
        let congestion = proxy_field(proxy, "congestion-controller");
        if !congestion.is_empty() && !congestion.eq_ignore_ascii_case("bbr") {
            return Err(format!(
                "tuic proxy {} congestion-controller {} is not supported by the embedded TUIC adapter yet",
                proxy.name, congestion
            ));
        }
        return Ok(format!(
            "{pad}type: tuic\n{pad}uuid: {}\n{pad}password: {}\n",
            yaml_quote(uuid),
            yaml_quote(password)
        ));
    }
    if proxy_type == "direct" {
        return Ok(format!("{pad}type: direct\n"));
    }

    if proxy_type == "ss" || proxy_type == "shadowsocks" {
        let cipher = proxy_field(proxy, "cipher");
        let password = proxy_field(proxy, "password");
        if cipher.is_empty() || password.is_empty() {
            return Err(format!(
                "shadowsocks proxy {} missing cipher/password",
                proxy.name
            ));
        }
        return Ok(format!(
            "{pad}type: shadowsocks\n{pad}cipher: {}\n{pad}password: {}\n{pad}udp_enabled: {}\n",
            yaml_quote(cipher),
            yaml_quote(password),
            if proxy_udp_enabled(proxy) {
                "true"
            } else {
                "false"
            }
        ));
    }

    if proxy_type == "snell" {
        let cipher = proxy_field(proxy, "cipher");
        let password = proxy_field(proxy, "password");
        if cipher.is_empty() || password.is_empty() {
            return Err(format!(
                "snell proxy {} missing cipher/password",
                proxy.name
            ));
        }
        return Ok(format!(
            "{pad}type: snell\n{pad}cipher: {}\n{pad}password: {}\n{pad}udp_enabled: {}\n",
            yaml_quote(cipher),
            yaml_quote(password),
            if proxy_udp_enabled(proxy) {
                "true"
            } else {
                "false"
            }
        ));
    }

    if proxy_type == "socks" || proxy_type == "socks5" {
        let username = proxy_field(proxy, "username");
        let password = proxy_field(proxy, "password");
        let mut out = format!("{pad}type: socks\n");
        if !username.is_empty() {
            out.push_str(&format!("{pad}username: {}\n", yaml_quote(username)));
        }
        if !password.is_empty() {
            out.push_str(&format!("{pad}password: {}\n", yaml_quote(password)));
        }
        return Ok(out);
    }

    if proxy_type == "http" || proxy_type == "https" {
        let username = proxy_field(proxy, "username");
        let password = proxy_field(proxy, "password");
        let mut out = format!("{pad}type: http\n");
        if !username.is_empty() {
            out.push_str(&format!("{pad}username: {}\n", yaml_quote(username)));
        }
        if !password.is_empty() {
            out.push_str(&format!("{pad}password: {}\n", yaml_quote(password)));
        }
        return Ok(out);
    }

    if proxy_type == "vmess" {
        let user_id = proxy_field(proxy, "uuid");
        if user_id.is_empty() {
            return Err(format!("vmess proxy {} missing uuid", proxy.name));
        }
        let cipher = proxy_field(proxy, "cipher");
        let mut out = format!(
            "{pad}type: vmess\n{pad}cipher: {}\n{pad}user_id: {}\n{pad}udp_enabled: {}\n",
            yaml_quote(if cipher.is_empty() { "any" } else { cipher }),
            yaml_quote(user_id),
            if proxy_udp_enabled(proxy) {
                "true"
            } else {
                "false"
            }
        );
        append_h2mux_yaml(proxy, &mut out, &pad);
        return Ok(out);
    }

    if proxy_type == "vless" {
        let user_id = proxy_field(proxy, "uuid");
        if user_id.is_empty() {
            return Err(format!("vless proxy {} missing uuid", proxy.name));
        }
        let mut out = format!(
            "{pad}type: vless\n{pad}user_id: {}\n{pad}udp_enabled: {}\n",
            yaml_quote(user_id),
            if proxy_udp_enabled(proxy) {
                "true"
            } else {
                "false"
            }
        );
        append_h2mux_yaml(proxy, &mut out, &pad);
        return Ok(out);
    }

    if proxy_type == "trojan" {
        let password = proxy_field(proxy, "password");
        if password.is_empty() {
            return Err(format!("trojan proxy {} missing password", proxy.name));
        }
        let mut out = format!(
            "{pad}type: trojan\n{pad}password: {}\n",
            yaml_quote(password)
        );
        append_h2mux_yaml(proxy, &mut out, &pad);
        return Ok(out);
    }

    if proxy_type == "anytls" || proxy_type == "any-tls" {
        let password = proxy_field(proxy, "password");
        if password.is_empty() {
            return Err(format!("anytls proxy {} missing password", proxy.name));
        }
        return Ok(format!(
            "{pad}type: anytls\n{pad}password: {}\n{pad}udp_enabled: {}\n",
            yaml_quote(password),
            if proxy_udp_enabled(proxy) {
                "true"
            } else {
                "false"
            }
        ));
    }

    if proxy_type == "naive" || proxy_type == "naiveproxy" {
        let username = proxy_field(proxy, "username");
        let password = proxy_field(proxy, "password");
        if username.is_empty() || password.is_empty() {
            return Err(format!(
                "naiveproxy proxy {} missing username/password",
                proxy.name
            ));
        }
        return Ok(format!(
            "{pad}type: naiveproxy\n{pad}username: {}\n{pad}password: {}\n{pad}padding: true\n",
            yaml_quote(username),
            yaml_quote(password)
        ));
    }

    Err(format!(
        "proxy {} type {} is not supported by the embedded shoes adapter yet",
        proxy.name, proxy.proxy_type
    ))
}

fn unsupported_network_error(proxy: &ProxyNode, network: &str) -> String {
    match network {
        "grpc" => format!(
            "proxy {} network grpc is not supported: the vendored shoes backend has no Clash/Xray gRPC client transport wrapper",
            proxy.name
        ),
        "h2" | "http" | "http2" => format!(
            "proxy {} network {} is not supported: Clash/Xray HTTP/2 transport is not the same as shoes h2mux and must not be mapped silently",
            proxy.name, network
        ),
        other => format!(
            "proxy {} network {} is not supported by the embedded shoes adapter yet",
            proxy.name, other
        ),
    }
}

fn wrap_websocket(proxy: &ProxyNode, inner: String, indent: usize) -> String {
    let pad = protocol_indent(indent);
    let inner_pad = protocol_indent(indent + 2);
    let path = proxy_field_any(proxy, &["path", "ws-path"]);
    let host = proxy_field_any(proxy, &["ws-host", "host"]);
    let mut out = format!("{pad}type: ws\n");
    if !path.is_empty() {
        out.push_str(&format!("{pad}matching_path: {}\n", yaml_quote(path)));
    }
    if !host.is_empty() {
        out.push_str(&format!(
            "{pad}matching_headers:\n{pad}  Host: {}\n",
            yaml_quote(host)
        ));
    }
    out.push_str(&format!("{pad}protocol:\n"));
    for line in inner.lines() {
        out.push_str(&inner_pad);
        out.push_str(line);
        out.push('\n');
    }
    out
}

fn first_csv_value(value: &str) -> String {
    value.split(',').next().map(trim_quote).unwrap_or_default()
}

fn normalize_http_path(path: &str) -> String {
    if path.is_empty() {
        "/".to_string()
    } else if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    }
}

fn wrap_http2_transport(proxy: &ProxyNode, inner: String, indent: usize) -> String {
    let pad = protocol_indent(indent);
    let inner_pad = protocol_indent(indent + 2);
    let path = normalize_http_path(proxy_field_any(proxy, &["h2-path", "path"]));
    let host = first_csv_value(proxy_field_any(
        proxy,
        &["h2-host", "host", "servername", "sni"],
    ));
    let host = if host.is_empty() {
        proxy_field(proxy, "server").to_string()
    } else {
        host
    };
    let mut out = format!("{pad}type: h2\n{pad}path: {}\n", yaml_quote(&path));
    if !host.is_empty() {
        out.push_str(&format!("{pad}host: {}\n", yaml_quote(&host)));
    }
    out.push_str(&format!("{pad}protocol:\n"));
    for line in inner.lines() {
        out.push_str(&inner_pad);
        out.push_str(line);
        out.push('\n');
    }
    out
}

fn wrap_grpc_transport(proxy: &ProxyNode, inner: String, indent: usize) -> String {
    let pad = protocol_indent(indent);
    let inner_pad = protocol_indent(indent + 2);
    let service_name = proxy_field(proxy, "grpc-service-name");
    let authority = first_csv_value(proxy_field_any(
        proxy,
        &["grpc-authority", "host", "servername", "sni"],
    ));
    let authority = if authority.is_empty() {
        proxy_field(proxy, "server").to_string()
    } else {
        authority
    };
    let mut out = format!("{pad}type: grpc\n");
    if !service_name.is_empty() {
        out.push_str(&format!(
            "{pad}service_name: {}\n",
            yaml_quote(service_name)
        ));
    }
    if !authority.is_empty() {
        out.push_str(&format!("{pad}authority: {}\n", yaml_quote(&authority)));
    }
    out.push_str(&format!("{pad}protocol:\n"));
    for line in inner.lines() {
        out.push_str(&inner_pad);
        out.push_str(line);
        out.push('\n');
    }
    out
}

fn wrap_tls(
    proxy: &ProxyNode,
    inner: String,
    indent: usize,
    runtime_config: &RuntimeConfig,
) -> String {
    let pad = protocol_indent(indent);
    let inner_pad = protocol_indent(indent + 2);
    let sni = proxy_field_any(proxy, &["sni", "servername", "host"]);
    let sni = if sni.is_empty() {
        proxy_field(proxy, "server")
    } else {
        sni
    };
    let mut out = format!("{pad}type: tls\n");
    if let Some(verify) = tls_verify_yaml_value(proxy, runtime_config) {
        out.push_str(&format!("{pad}verify: {verify}\n"));
    }
    let server_fp = proxy_field(proxy, "server-fingerprint");
    if !server_fp.is_empty() {
        out.push_str(&format!(
            "{pad}server_fingerprints: {}\n",
            yaml_quote(server_fp)
        ));
    }
    let client_fp = proxy_field(proxy, "client-fingerprint");
    if !client_fp.is_empty() {
        out.push_str(&format!(
            "{pad}client_fingerprint: {}\n",
            yaml_quote(client_fp)
        ));
    } else if runtime_config.tls_client_mode == TlsClientMode::Chrome {
        out.push_str(&format!("{pad}client_fingerprint: \"chrome\"\n"));
    }
    let alpn = proxy_field(proxy, "alpn");
    if !alpn.is_empty() {
        out.push_str(&format!("{pad}alpn_protocols: {}\n", yaml_quote(alpn)));
    }
    if !sni.is_empty() {
        out.push_str(&format!("{pad}sni_hostname: {}\n", yaml_quote(sni)));
    }
    if proxy.proxy_type.eq_ignore_ascii_case("naive")
        || proxy.proxy_type.eq_ignore_ascii_case("naiveproxy")
        || proxy_field(proxy, "network").eq_ignore_ascii_case("h2")
        || proxy_field(proxy, "network").eq_ignore_ascii_case("http")
        || proxy_field(proxy, "network").eq_ignore_ascii_case("http2")
        || proxy_field(proxy, "network").eq_ignore_ascii_case("grpc")
    {
        if alpn.is_empty() {
            out.push_str(&format!("{pad}alpn_protocols: \"h2\"\n"));
        }
    }
    out.push_str(&format!("{pad}protocol:\n"));
    for line in inner.lines() {
        out.push_str(&inner_pad);
        out.push_str(line);
        out.push('\n');
    }
    out
}

fn tls_verify_yaml_value(
    proxy: &ProxyNode,
    runtime_config: &RuntimeConfig,
) -> Option<&'static str> {
    let skip_verify = proxy_field(proxy, "skip-cert-verify");
    if !skip_verify.is_empty() {
        return Some(if truthy(skip_verify) { "false" } else { "true" });
    }

    if runtime_config.tls_client_mode == TlsClientMode::Chrome
        && proxy.proxy_type.eq_ignore_ascii_case("trojan")
    {
        let server = proxy_field(proxy, "server");
        let sni = proxy_field_any(proxy, &["sni", "servername", "server-name", "server_name"]);
        if !server.is_empty() && !sni.is_empty() && !server.eq_ignore_ascii_case(&sni) {
            // Clash subscriptions often omit skip-cert-verify for Trojan nodes
            // that intentionally front through an SNI different from server.
            return Some("false");
        }
    }

    None
}

fn wrap_reality(proxy: &ProxyNode, inner: String, indent: usize) -> Result<String, String> {
    let public_key = proxy_field_any(proxy, &["pbk", "public-key", "public_key"]);
    if public_key.is_empty() {
        return Err(format!("reality proxy {} missing public key", proxy.name));
    }
    let pad = protocol_indent(indent);
    let inner_pad = protocol_indent(indent + 2);
    let sni = proxy_field_any(proxy, &["sni", "servername", "server-name", "server_name"]);
    let short_id = proxy_field_any(proxy, &["sid", "short-id", "short_id"]);
    let vision = proxy_field(proxy, "flow").contains("vision");
    let mut out = format!(
        "{pad}type: reality\n{pad}public_key: {}\n",
        yaml_quote(public_key)
    );
    if !short_id.is_empty() {
        out.push_str(&format!("{pad}short_id: {}\n", yaml_quote(short_id)));
    }
    if !sni.is_empty() {
        out.push_str(&format!("{pad}sni_hostname: {}\n", yaml_quote(sni)));
    }
    if vision {
        out.push_str(&format!("{pad}vision: true\n"));
    }
    out.push_str(&format!("{pad}protocol:\n"));
    for line in inner.lines() {
        out.push_str(&inner_pad);
        out.push_str(line);
        out.push('\n');
    }
    Ok(out)
}

fn wrap_shadow_tls(proxy: &ProxyNode, inner: String, indent: usize) -> Result<String, String> {
    let password = proxy_field_any(
        proxy,
        &["shadow-tls-password", "shadowtls-password", "password"],
    );
    if password.is_empty() {
        return Err(format!("shadowtls proxy {} missing password", proxy.name));
    }
    let sni = proxy_field_any(
        proxy,
        &[
            "shadow-tls-sni",
            "shadowtls-sni",
            "sni",
            "servername",
            "host",
        ],
    );
    let pad = protocol_indent(indent);
    let inner_pad = protocol_indent(indent + 2);
    let mut out = format!(
        "{pad}type: shadowtls\n{pad}password: {}\n",
        yaml_quote(password)
    );
    if !sni.is_empty() {
        out.push_str(&format!("{pad}sni_hostname: {}\n", yaml_quote(sni)));
    }
    out.push_str(&format!("{pad}protocol:\n"));
    for line in inner.lines() {
        out.push_str(&inner_pad);
        out.push_str(line);
        out.push('\n');
    }
    Ok(out)
}

fn build_proxy_protocol(
    proxy: &ProxyNode,
    indent: usize,
    runtime_config: &RuntimeConfig,
) -> Result<String, String> {
    let mut protocol = build_base_protocol(proxy, indent)?;
    let network = proxy_field(proxy, "network").to_lowercase();
    if network == "ws" || network == "websocket" {
        protocol = wrap_websocket(proxy, protocol, indent);
    } else if network == "h2" || network == "http" || network == "http2" {
        protocol = wrap_http2_transport(proxy, protocol, indent);
    } else if network == "grpc" {
        protocol = wrap_grpc_transport(proxy, protocol, indent);
    } else if !network.is_empty() && network != "tcp" {
        return Err(unsupported_network_error(proxy, &network));
    }
    let plugin = proxy_field(proxy, "plugin").to_lowercase();
    if plugin == "shadow-tls" || plugin == "shadowtls" {
        protocol = wrap_shadow_tls(proxy, protocol, indent)?;
    } else if plugin == "v2ray-plugin" || plugin == "v2ray_plugin" {
        let mode = proxy_field(proxy, "plugin-mode").to_lowercase();
        if !mode.is_empty() && mode != "websocket" && mode != "ws" {
            return Err(format!(
                "proxy {} v2ray-plugin mode {} is not supported by the embedded shoes adapter yet",
                proxy.name, mode
            ));
        }
        if network != "ws" && network != "websocket" {
            protocol = wrap_websocket(proxy, protocol, indent);
        }
    } else if !plugin.is_empty() {
        return Err(format!(
            "proxy {} plugin {} is not supported by the embedded shoes adapter yet",
            proxy.name, plugin
        ));
    }
    if proxy_field(proxy, "security").eq_ignore_ascii_case("reality") {
        protocol = wrap_reality(proxy, protocol, indent)?;
    } else if truthy(proxy_field(proxy, "tls"))
        || truthy(proxy_field(proxy, "plugin-tls"))
        || proxy_field(proxy, "security").eq_ignore_ascii_case("tls")
        || proxy.proxy_type.eq_ignore_ascii_case("trojan")
        || proxy.proxy_type.eq_ignore_ascii_case("anytls")
        || proxy.proxy_type.eq_ignore_ascii_case("any-tls")
        || proxy.proxy_type.eq_ignore_ascii_case("naive")
        || proxy.proxy_type.eq_ignore_ascii_case("naiveproxy")
    {
        if !falsy(proxy_field(proxy, "tls")) {
            protocol = wrap_tls(proxy, protocol, indent, runtime_config);
        }
    }
    Ok(protocol)
}

fn build_shoes_client_chain(
    proxy: &ProxyNode,
    runtime_config: &RuntimeConfig,
) -> Result<String, String> {
    let proxy_type = proxy.proxy_type.to_lowercase();
    if proxy_type == "direct" {
        return Ok("        - protocol:\n            type: direct\n".to_string());
    }
    let server = proxy_field(proxy, "server");
    let port = proxy_field(proxy, "port");
    if server.is_empty() || port.is_empty() {
        return Err(format!("proxy {} missing server/port", proxy.name));
    }
    let protocol = build_proxy_protocol(proxy, 12, runtime_config)?;
    let mut out = format!(
        "        - address: {}\n          protocol:\n{}",
        yaml_quote(&format!("{server}:{port}")),
        protocol
    );
    if proxy_requires_quic_transport(proxy) {
        append_quic_client_settings(proxy, &mut out);
    }
    Ok(out)
}

fn proxy_requires_quic_transport(proxy: &ProxyNode) -> bool {
    matches!(
        proxy.proxy_type.to_ascii_lowercase().as_str(),
        "hysteria2" | "hy2" | "hysteria" | "tuic" | "tuic-v5" | "tuicv5"
    )
}

fn append_quic_client_settings(proxy: &ProxyNode, out: &mut String) {
    out.push_str("          transport: quic\n");
    let sni = proxy_field_any(
        proxy,
        &["sni", "servername", "server-name", "server_name", "host"],
    );
    let sni = if sni.is_empty() {
        proxy_field(proxy, "server")
    } else {
        sni
    };
    let skip_verify = proxy_field(proxy, "skip-cert-verify");
    let alpn = proxy_field(proxy, "alpn");
    if skip_verify.is_empty() && sni.is_empty() && alpn.is_empty() {
        return;
    }
    out.push_str("          quic_settings:\n");
    if !skip_verify.is_empty() {
        out.push_str(&format!(
            "            verify: {}\n",
            if truthy(skip_verify) { "false" } else { "true" }
        ));
    }
    if !sni.is_empty() {
        out.push_str(&format!("            sni_hostname: {}\n", yaml_quote(sni)));
    }
    if !alpn.is_empty() {
        out.push_str(&format!(
            "            alpn_protocols: {}\n",
            yaml_quote(alpn)
        ));
    }
}

#[allow(dead_code)]
fn build_probe_client_group(proxy: &ProxyNode) -> Result<String, String> {
    let chain = build_shoes_client_chain(proxy, &RuntimeConfig::default())?;
    Ok(format!(
        "- client_group: \"__clashhm_probe\"\n  client_proxies:\n{chain}"
    ))
}

fn build_direct_client_chain() -> String {
    "        - protocol:\n            type: direct\n".to_string()
}

#[allow(dead_code)]
fn build_rule_client_chain(
    target: &str,
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
) -> Result<Option<String>, String> {
    build_rule_client_chain_with_runtime(target, groups, proxies, &RuntimeConfig::default())
}

fn build_rule_client_chain_with_runtime(
    target: &str,
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    runtime_config: &RuntimeConfig,
) -> Result<Option<String>, String> {
    build_rule_client_chain_inner(target, groups, proxies, runtime_config, 0)
}

fn build_rule_client_chain_inner(
    target: &str,
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    runtime_config: &RuntimeConfig,
    depth: usize,
) -> Result<Option<String>, String> {
    if depth > groups.len() + 1 {
        return Err(format!(
            "proxy group selection loop while resolving {target}"
        ));
    }
    if target.eq_ignore_ascii_case("DIRECT") {
        return Ok(Some(build_direct_client_chain()));
    }
    if target.eq_ignore_ascii_case("REJECT") || target.eq_ignore_ascii_case("REJECT-DROP") {
        return Ok(None);
    }
    if let Some(proxy) = proxies.iter().find(|proxy| proxy.name == target) {
        return build_shoes_client_chain(proxy, runtime_config).map(Some);
    }
    if let Some(selected) = selected_target_for_group(target, groups) {
        return build_rule_client_chain_inner(selected, groups, proxies, runtime_config, depth + 1);
    }
    if depth == 0 {
        let proxy = selected_proxy(groups, proxies)
            .ok_or_else(|| format!("rule target {target} did not resolve to a proxy"))?;
        return build_shoes_client_chain(proxy, runtime_config).map(Some);
    }
    Err(format!("rule target {target} did not resolve to a proxy"))
}

fn rule_mask(rule: &ClashRule) -> Option<String> {
    match rule.rule_type.as_str() {
        "MATCH" => Some("0.0.0.0/0".to_string()),
        "DOMAIN" => Some(rule.payload.clone()),
        "DOMAIN-SUFFIX" => Some(rule.payload.trim_start_matches('.').to_string()),
        "IP-CIDR" | "IP-CIDR6" => Some(rule.payload.clone()),
        "DST-PORT" => Some(format!("0.0.0.0/0:{}", rule.payload)),
        _ => None,
    }
}

fn read_pb_varint(bytes: &[u8], pos: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    let mut shift = 0u32;
    while *pos < bytes.len() && shift < 64 {
        let byte = bytes[*pos];
        *pos += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(value);
        }
        shift += 7;
    }
    None
}

fn read_pb_len<'a>(bytes: &'a [u8], pos: &mut usize) -> Option<&'a [u8]> {
    let len = read_pb_varint(bytes, pos)? as usize;
    if bytes.len().saturating_sub(*pos) < len {
        return None;
    }
    let out = &bytes[*pos..*pos + len];
    *pos += len;
    Some(out)
}

fn skip_pb_field(bytes: &[u8], pos: &mut usize, wire_type: u64) -> Option<()> {
    match wire_type {
        0 => read_pb_varint(bytes, pos).map(|_| ()),
        1 => {
            *pos = pos.checked_add(8)?;
            (*pos <= bytes.len()).then_some(())
        }
        2 => read_pb_len(bytes, pos).map(|_| ()),
        5 => {
            *pos = pos.checked_add(4)?;
            (*pos <= bytes.len()).then_some(())
        }
        _ => None,
    }
}

fn parse_geosite_attribute(bytes: &[u8]) -> Option<String> {
    let mut pos = 0usize;
    let mut key = String::new();
    let mut bool_value = false;
    while pos < bytes.len() {
        let tag = read_pb_varint(bytes, &mut pos)?;
        let field = tag >> 3;
        let wire_type = tag & 0x07;
        match (field, wire_type) {
            (1, 2) => key = String::from_utf8_lossy(read_pb_len(bytes, &mut pos)?).to_string(),
            (2, 0) => bool_value = read_pb_varint(bytes, &mut pos)? != 0,
            _ => skip_pb_field(bytes, &mut pos, wire_type)?,
        }
    }
    if bool_value && !key.is_empty() {
        Some(key.to_ascii_lowercase())
    } else {
        None
    }
}

fn parse_geosite_domain(bytes: &[u8]) -> Option<(u64, String, Vec<String>)> {
    let mut pos = 0usize;
    let mut domain_type = 0u64;
    let mut value = String::new();
    let mut attrs = Vec::new();
    while pos < bytes.len() {
        let tag = read_pb_varint(bytes, &mut pos)?;
        let field = tag >> 3;
        let wire_type = tag & 0x07;
        match (field, wire_type) {
            (1, 0) => domain_type = read_pb_varint(bytes, &mut pos)?,
            (2, 2) => value = String::from_utf8_lossy(read_pb_len(bytes, &mut pos)?).to_string(),
            (3, 2) => {
                if let Some(attr) = parse_geosite_attribute(read_pb_len(bytes, &mut pos)?) {
                    attrs.push(attr);
                }
            }
            _ => skip_pb_field(bytes, &mut pos, wire_type)?,
        }
    }
    (!value.is_empty()).then_some((domain_type, value, attrs))
}

fn parse_geosite_entry(bytes: &[u8]) -> Option<Vec<(String, GeositeCategory)>> {
    let mut pos = 0usize;
    let mut category = String::new();
    let mut entries: Vec<(u64, String, Vec<String>)> = Vec::new();
    while pos < bytes.len() {
        let tag = read_pb_varint(bytes, &mut pos)?;
        let field = tag >> 3;
        let wire_type = tag & 0x07;
        match (field, wire_type) {
            (1, 2) => {
                category =
                    String::from_utf8_lossy(read_pb_len(bytes, &mut pos)?).to_ascii_lowercase()
            }
            (2, 2) => {
                if let Some(domain) = parse_geosite_domain(read_pb_len(bytes, &mut pos)?) {
                    entries.push(domain);
                }
            }
            _ => skip_pb_field(bytes, &mut pos, wire_type)?,
        }
    }
    if category.is_empty() {
        return None;
    }
    let mut all = GeositeCategory::default();
    let mut by_attr: BTreeMap<String, GeositeCategory> = BTreeMap::new();
    for (domain_type, value, attrs) in entries {
        add_geosite_domain(&mut all, domain_type, &value);
        for attr in attrs {
            add_geosite_domain(by_attr.entry(attr).or_default(), domain_type, &value);
        }
    }
    let mut output = vec![(category.clone(), all)];
    for (attr, attr_category) in by_attr {
        output.push((format!("{category}@{attr}"), attr_category));
    }
    Some(output)
}

fn add_geosite_domain(category: &mut GeositeCategory, domain_type: u64, value: &str) {
    let value = value.trim().trim_start_matches('.').to_ascii_lowercase();
    if value.is_empty() {
        return;
    }
    match domain_type {
        0 => category.keywords.push(value),
        2 | 3 => category.masks.push(value),
        1 => category.skipped_regex += 1,
        _ => {}
    }
}

fn parse_geosite_dat(bytes: &[u8]) -> Result<BTreeMap<String, GeositeCategory>, String> {
    let mut pos = 0usize;
    let mut map = BTreeMap::new();
    while pos < bytes.len() {
        let tag = read_pb_varint(bytes, &mut pos).ok_or("invalid geosite protobuf tag")?;
        let field = tag >> 3;
        let wire_type = tag & 0x07;
        match (field, wire_type) {
            (1, 2) => {
                if let Some(entries) = parse_geosite_entry(
                    read_pb_len(bytes, &mut pos).ok_or("invalid geosite entry")?,
                ) {
                    for (name, category) in entries {
                        map.insert(name, category);
                    }
                }
            }
            _ => skip_pb_field(bytes, &mut pos, wire_type)
                .ok_or_else(|| format!("invalid geosite protobuf wire type {wire_type}"))?,
        }
    }
    Ok(map)
}

fn geosite_data() -> Result<&'static BTreeMap<String, GeositeCategory>, String> {
    GEOSITE_DATA
        .get_or_init(|| {
            let dat = miniz_oxide::inflate::decompress_to_vec_zlib(GEOSITE_DAT_Z)
                .map_err(|e| format!("failed to decompress geosite.dat: {e:?}"))?;
            parse_geosite_dat(&dat)
        })
        .as_ref()
        .map_err(Clone::clone)
}

fn hardcoded_geosite_category(payload: &str) -> Option<GeositeCategory> {
    match payload
        .trim()
        .trim_start_matches("geosite:")
        .to_ascii_lowercase()
        .as_str()
    {
        "cn" => Some(GeositeCategory {
            masks: vec!["cn".to_string()],
            ..GeositeCategory::default()
        }),
        "private" | "local" | "lan" => Some(GeositeCategory {
            masks: vec![
                "localhost".to_string(),
                "local".to_string(),
                "lan".to_string(),
                "home.arpa".to_string(),
            ],
            ..GeositeCategory::default()
        }),
        _ => None,
    }
}

fn geosite_category(payload: &str) -> Option<GeositeCategory> {
    let category = payload
        .trim()
        .trim_start_matches("geosite:")
        .to_ascii_lowercase();
    if let Some(entry) = hardcoded_geosite_category(&category) {
        return Some(entry);
    }
    if let Ok(data) = geosite_data() {
        if let Some(entry) = data.get(category.as_str()) {
            return Some(entry.clone());
        }
    }
    None
}

fn geoip_cidrs(payload: &str) -> Option<Vec<&'static str>> {
    match payload
        .trim()
        .trim_start_matches("geoip:")
        .to_ascii_lowercase()
        .as_str()
    {
        "private" | "lan" => Some(vec![
            "0.0.0.0/8",
            "10.0.0.0/8",
            "100.64.0.0/10",
            "127.0.0.0/8",
            "169.254.0.0/16",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "224.0.0.0/4",
            "::1/128",
            "fc00::/7",
            "fe80::/10",
        ]),
        _ => None,
    }
}

fn geoip_country(payload: &str) -> Option<String> {
    let country = payload
        .trim()
        .trim_start_matches("geoip:")
        .trim()
        .to_ascii_uppercase();
    if country.len() == 2 && country.chars().all(|ch| ch.is_ascii_alphabetic()) {
        Some(country)
    } else {
        None
    }
}

fn modeled_rule_masks(rule: &ClashRule) -> Option<Vec<String>> {
    if let Some(mask) = rule_mask(rule) {
        return Some(vec![mask]);
    }
    if rule.rule_type == "GEOIP" {
        return geoip_cidrs(&rule.payload)
            .map(|cidrs| cidrs.into_iter().map(str::to_string).collect());
    }
    None
}

fn modeled_geosite_category(rule: &ClashRule) -> Option<GeositeCategory> {
    if rule.rule_type == "GEOSITE" {
        return geosite_category(&rule.payload);
    }
    None
}

fn modeled_geoip_country(rule: &ClashRule) -> Option<String> {
    if rule.rule_type == "GEOIP" && geoip_cidrs(&rule.payload).is_none() {
        return geoip_country(&rule.payload);
    }
    None
}

fn build_domain_keyword_rule_yaml(
    keyword: &str,
    target: &str,
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    runtime_config: &RuntimeConfig,
) -> Result<String, String> {
    build_domain_keywords_rule_yaml(
        &[keyword.to_string()],
        target,
        groups,
        proxies,
        runtime_config,
    )
}

fn yaml_quoted_list(values: &[String], indent: &str) -> String {
    if values.len() == 1 {
        return yaml_quote(&values[0]);
    }
    let mut out = String::from("\n");
    for value in values {
        out.push_str(indent);
        out.push_str("- ");
        out.push_str(&yaml_quote(value));
        out.push('\n');
    }
    out.trim_end().to_string()
}

fn build_domain_keywords_rule_yaml(
    keywords: &[String],
    target: &str,
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    runtime_config: &RuntimeConfig,
) -> Result<String, String> {
    if keywords.is_empty() {
        return Ok(String::new());
    }
    match build_rule_client_chain_with_runtime(target, groups, proxies, runtime_config)? {
        Some(chain) => Ok(format!(
            "    - masks: \"0.0.0.0/0\"\n      domain_keywords: {}\n      action: allow\n      client_chain:\n{chain}",
            yaml_quoted_list(keywords, "        ")
        )),
        None => Ok(format!(
            "    - masks: \"0.0.0.0/0\"\n      domain_keywords: {}\n      action: block\n",
            yaml_quoted_list(keywords, "        ")
        )),
    }
}

fn skipped_rule_types(rules: &[ClashRule]) -> Vec<String> {
    let mut types = Vec::new();
    for rule in rules {
        if rule.rule_type == "DOMAIN-KEYWORD"
            || modeled_rule_masks(rule).is_some()
            || modeled_geosite_category(rule).is_some()
            || modeled_geoip_country(rule).is_some()
        {
            continue;
        }
        if !types.contains(&rule.rule_type) {
            types.push(rule.rule_type.clone());
        }
    }
    types
}

fn skipped_rule_count(rules: &[ClashRule]) -> usize {
    rules
        .iter()
        .filter(|rule| {
            rule.rule_type != "DOMAIN-KEYWORD"
                && modeled_rule_masks(rule).is_none()
                && modeled_geosite_category(rule).is_none()
                && modeled_geoip_country(rule).is_none()
        })
        .count()
}

fn json_string_array(values: &[String]) -> String {
    let mut out = String::from("[");
    for (idx, value) in values.iter().enumerate() {
        if idx > 0 {
            out.push(',');
        }
        out.push_str(&format!("\"{}\"", json_escape(value)));
    }
    out.push(']');
    out
}

fn build_rule_yaml(
    mask: &str,
    target: &str,
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    runtime_config: &RuntimeConfig,
) -> Result<String, String> {
    match build_rule_client_chain_with_runtime(target, groups, proxies, runtime_config)? {
        Some(chain) => Ok(format!(
            "    - masks: {}\n      action: allow\n      client_chain:\n{chain}",
            yaml_quote(mask)
        )),
        None => Ok(format!(
            "    - masks: {}\n      action: block\n",
            yaml_quote(mask)
        )),
    }
}

fn build_rule_masks_yaml(
    masks: &[String],
    target: &str,
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    runtime_config: &RuntimeConfig,
) -> Result<String, String> {
    if masks.is_empty() {
        return Ok(String::new());
    }
    match build_rule_client_chain_with_runtime(target, groups, proxies, runtime_config)? {
        Some(chain) => Ok(format!(
            "    - masks: {}\n      action: allow\n      client_chain:\n{chain}",
            yaml_quoted_list(masks, "        ")
        )),
        None => Ok(format!(
            "    - masks: {}\n      action: block\n",
            yaml_quoted_list(masks, "        ")
        )),
    }
}

fn build_geoip_country_rule_yaml(
    country: &str,
    target: &str,
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    runtime_config: &RuntimeConfig,
) -> Result<String, String> {
    match build_rule_client_chain_with_runtime(target, groups, proxies, runtime_config)? {
        Some(chain) => Ok(format!(
            "    - masks: \"0.0.0.0/0\"\n      geoip_countries: {}\n      action: allow\n      client_chain:\n{chain}",
            yaml_quote(country)
        )),
        None => Ok(format!(
            "    - masks: \"0.0.0.0/0\"\n      geoip_countries: {}\n      action: block\n",
            yaml_quote(country)
        )),
    }
}

fn build_default_rule(
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    runtime_config: &RuntimeConfig,
) -> Result<String, String> {
    let target = selected_group(groups)
        .and_then(|group| {
            if group.now.is_empty() {
                group.all.first().map(String::as_str)
            } else {
                Some(group.now.as_str())
            }
        })
        .or_else(|| proxies.first().map(|proxy| proxy.name.as_str()))
        .ok_or_else(|| "no selected proxy found in Clash config".to_string())?;
    build_rule_yaml("0.0.0.0/0", target, groups, proxies, runtime_config)
}

#[allow(dead_code)]
fn build_shoes_rules(
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    rules: &[ClashRule],
) -> Result<String, String> {
    build_shoes_rules_with_runtime(groups, proxies, rules, &RuntimeConfig::default())
}

fn build_shoes_rules_with_runtime(
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    rules: &[ClashRule],
    runtime_config: &RuntimeConfig,
) -> Result<String, String> {
    let mut out = String::new();
    for rule in rules {
        if rule.rule_type == "DOMAIN-KEYWORD" {
            out.push_str(&build_domain_keyword_rule_yaml(
                &rule.payload,
                &rule.target,
                groups,
                proxies,
                runtime_config,
            )?);
            continue;
        }
        if let Some(category) = modeled_geosite_category(rule) {
            out.push_str(&build_rule_masks_yaml(
                &category.masks,
                &rule.target,
                groups,
                proxies,
                runtime_config,
            )?);
            out.push_str(&build_domain_keywords_rule_yaml(
                &category.keywords,
                &rule.target,
                groups,
                proxies,
                runtime_config,
            )?);
            continue;
        }
        if let Some(country) = modeled_geoip_country(rule) {
            out.push_str(&build_geoip_country_rule_yaml(
                &country,
                &rule.target,
                groups,
                proxies,
                runtime_config,
            )?);
            continue;
        }
        let Some(masks) = modeled_rule_masks(rule) else {
            continue;
        };
        for mask in masks {
            out.push_str(&build_rule_yaml(
                &mask,
                &rule.target,
                groups,
                proxies,
                runtime_config,
            )?);
        }
    }
    if !out.contains("0.0.0.0/0") {
        out.push_str(&build_default_rule(groups, proxies, runtime_config)?);
    }
    Ok(out)
}

#[allow(dead_code)]
fn build_shoes_tun_config(
    tun_fd: i32,
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    rules: &[ClashRule],
) -> Result<String, String> {
    build_shoes_tun_config_with_runtime(tun_fd, groups, proxies, rules, &RuntimeConfig::default())
}

fn build_shoes_tun_config_with_runtime(
    tun_fd: i32,
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    rules: &[ClashRule],
    runtime_config: &RuntimeConfig,
) -> Result<String, String> {
    let rules_yaml = build_shoes_rules_with_runtime(groups, proxies, rules, runtime_config)?;
    Ok(format!(
        "- device_fd: {tun_fd}\n  address: \"10.249.0.1\"\n  netmask: \"255.255.255.252\"\n  mtu: 1400\n  tcp_enabled: true\n  udp_enabled: true\n  icmp_enabled: true\n  rules:\n{rules_yaml}"
    ))
}

fn effective_rules(
    mode: ConnectionMode,
    groups: &[ProxyGroup],
    rules: &[ClashRule],
) -> Vec<ClashRule> {
    match mode {
        ConnectionMode::Rule => rules.to_vec(),
        ConnectionMode::Global => {
            let target = selected_group(groups)
                .map(|group| group.name.clone())
                .or_else(|| groups.first().map(|group| group.name.clone()))
                .unwrap_or_else(|| "DIRECT".to_string());
            vec![ClashRule {
                rule_type: "MATCH".to_string(),
                payload: String::new(),
                target,
            }]
        }
        ConnectionMode::Direct => vec![ClashRule {
            rule_type: "MATCH".to_string(),
            payload: String::new(),
            target: "DIRECT".to_string(),
        }],
    }
}

#[cfg(feature = "shoes-backend")]
fn stop_shoes_backend() {
    let handle = shoes_handle().lock().unwrap().take();
    if let Some(mut handle) = handle {
        if let Some(tx) = handle.shutdown_tx.take() {
            let _ = tx.send(());
        }
        for _ in 0..50 {
            if !handle.running.load(Ordering::SeqCst) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        drop(handle.runtime);
    }
}

#[cfg(feature = "shoes-backend")]
fn build_fake_dns_config(dns_config: &ClashDnsConfig) -> shoes::tun::fake_dns::FakeDnsConfig {
    use shoes::tun::fake_dns::{FakeDnsConfig, FakeIpFilterEntry};

    let (fake_ip_range_base, fake_ip_range_prefix) = parse_ipv4_cidr(&dns_config.fake_ip_range)
        .unwrap_or((std::net::Ipv4Addr::new(198, 18, 0, 0), 16));
    let filter = dns_config
        .fake_ip_filter
        .iter()
        .map(|pattern| {
            let trimmed = pattern.trim();
            if let Some(keyword) = trimmed.strip_prefix("KEYWORD:") {
                FakeIpFilterEntry::Keyword(keyword.to_ascii_lowercase())
            } else if let Some(suffix) = trimmed.strip_prefix("+.") {
                FakeIpFilterEntry::Suffix(suffix.to_ascii_lowercase())
            } else if let Some(suffix) = trimmed.strip_prefix("*.") {
                FakeIpFilterEntry::Suffix(suffix.to_ascii_lowercase())
            } else {
                FakeIpFilterEntry::Exact(trimmed.to_ascii_lowercase())
            }
        })
        .collect();

    FakeDnsConfig {
        enabled: dns_config.enabled && dns_config.enhanced_mode.eq_ignore_ascii_case("fake-ip"),
        ipv6_enabled: dns_config.ipv6,
        fake_ip_range_base,
        fake_ip_range_prefix,
        fake_ip_filter: filter,
    }
}

#[cfg(feature = "shoes-backend")]
fn parse_ipv4_cidr(value: &str) -> Option<(std::net::Ipv4Addr, u8)> {
    let (addr, prefix) = value.trim().split_once('/')?;
    let addr = addr.parse::<std::net::Ipv4Addr>().ok()?;
    let prefix = prefix.parse::<u8>().ok()?;
    if prefix > 32 {
        return None;
    }
    Some((addr, prefix))
}

#[cfg(feature = "shoes-backend")]
fn normalize_clash_dns_url(url: &str) -> String {
    let trimmed = url.trim();
    if trimmed.parse::<std::net::IpAddr>().is_ok() {
        return format!("udp://{trimmed}");
    }
    if trimmed.parse::<std::net::SocketAddr>().is_ok() {
        return format!("udp://{trimmed}");
    }
    if trimmed.contains("://") {
        return trimmed.to_string();
    }
    format!("udp://{trimmed}")
}

#[cfg(feature = "shoes-backend")]
async fn build_clash_dns_resolvers(
    dns_config: &ClashDnsConfig,
) -> Result<
    (
        Arc<dyn shoes::resolver::Resolver>,
        Arc<dyn shoes::resolver::Resolver>,
    ),
    String,
> {
    use shoes::config::ExpandedDnsGroup;
    use shoes::config::ExpandedDnsSpec;
    use shoes::dns::{build_dns_registry, IpStrategy};
    use shoes::resolver::CachingNativeResolver;

    let bootstrap_specs: Vec<ExpandedDnsSpec> = dns_config
        .default_nameservers
        .iter()
        .map(|url| ExpandedDnsSpec {
            url: normalize_clash_dns_url(url),
            server_name: None,
            client_chains: vec![],
            bootstrap_url: None,
            ip_strategy: IpStrategy::Ipv4Only,
            timeout_secs: 5,
            connect_timeout_secs: 5,
            attempts: 2,
        })
        .collect();

    let bootstrap_group = ExpandedDnsGroup {
        name: "__bootstrap".to_string(),
        specs: if bootstrap_specs.is_empty() {
            vec![ExpandedDnsSpec {
                url: "system".to_string(),
                server_name: None,
                client_chains: vec![],
                bootstrap_url: None,
                ip_strategy: IpStrategy::Ipv4Only,
                timeout_secs: 5,
                connect_timeout_secs: 5,
                attempts: 1,
            }]
        } else {
            bootstrap_specs
        },
    };

    if dns_config.nameservers.is_empty() || !dns_config.enabled {
        let groups = vec![bootstrap_group];
        let registry = build_dns_registry(groups)
            .await
            .map_err(|e| format!("bootstrap DNS build failed: {e}"))?;
        let resolver = registry
            .get_by_name("__bootstrap")
            .unwrap_or_else(|| Arc::new(CachingNativeResolver::new()));
        return Ok((resolver.clone(), resolver));
    }

    let main_specs: Vec<ExpandedDnsSpec> = dns_config
        .nameservers
        .iter()
        .map(|url| {
            let normalized = normalize_clash_dns_url(url);
            let needs_bootstrap = normalized.contains("://") && !normalized.starts_with("udp://")
                || {
                    let after_scheme = normalized
                        .find("://")
                        .map(|i| &normalized[i + 3..])
                        .unwrap_or(&normalized);
                    let host_part = after_scheme.split('/').next().unwrap_or("");
                    let host_part = host_part.split(':').next().unwrap_or("");
                    host_part.parse::<std::net::IpAddr>().is_err()
                };
            ExpandedDnsSpec {
                url: normalized,
                server_name: None,
                client_chains: vec![],
                bootstrap_url: if needs_bootstrap {
                    Some("__bootstrap".to_string())
                } else {
                    None
                },
                ip_strategy: if dns_config.ipv6 {
                    IpStrategy::Ipv4ThenIpv6
                } else {
                    IpStrategy::Ipv4Only
                },
                timeout_secs: 5,
                connect_timeout_secs: 5,
                attempts: 1,
            }
        })
        .collect();

    let groups = vec![
        bootstrap_group,
        ExpandedDnsGroup {
            name: "__main".to_string(),
            specs: main_specs,
        },
    ];

    let registry = build_dns_registry(groups)
        .await
        .map_err(|e| format!("DNS registry build failed: {e}"))?;

    let main_resolver = registry
        .get_by_name("__main")
        .unwrap_or_else(|| Arc::new(CachingNativeResolver::new()));
    let bootstrap_resolver = registry
        .get_by_name("__bootstrap")
        .unwrap_or_else(|| Arc::new(CachingNativeResolver::new()));

    Ok((main_resolver, bootstrap_resolver))
}

#[cfg(feature = "shoes-backend")]
fn start_shoes_backend(shoes_yaml: String, dns_config: ClashDnsConfig) -> Result<(), String> {
    stop_shoes_backend();
    shoes::tun::reset_traffic_snapshot();
    let configs = shoes::config::load_config_str(&shoes_yaml).map_err(|e| e.to_string())?;
    let mut tun_config = None;
    for config in configs {
        if let shoes::config::Config::TunServer(config) = config {
            tun_config = Some(config);
            break;
        }
    }
    let tun_config =
        tun_config.ok_or_else(|| "generated shoes config did not contain TUN".to_string())?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(2)
        .build()
        .map_err(|e| e.to_string())?;
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let running = Arc::new(AtomicBool::new(true));
    let running_for_task = running.clone();
    let fake_dns_cfg = build_fake_dns_config(&dns_config);
    runtime.spawn(async move {
        shoes::tun::fake_dns::init(fake_dns_cfg);
        let (main_resolver, bootstrap_resolver) = match build_clash_dns_resolvers(&dns_config).await
        {
            Ok(resolvers) => resolvers,
            Err(e) => {
                eprintln!("DNS resolver build failed, falling back to native: {}", e);
                let native: Arc<dyn shoes::resolver::Resolver> =
                    Arc::new(shoes::resolver::NativeResolver::new());
                (native.clone(), native)
            }
        };
        let _ = shoes::tun::run_tun_from_config_with_resolvers(
            tun_config,
            shutdown_rx,
            false,
            main_resolver,
            bootstrap_resolver,
        )
        .await;
        running_for_task.store(false, Ordering::SeqCst);
    });
    *shoes_handle().lock().unwrap() = Some(ShoesHandle {
        runtime,
        shutdown_tx: Some(shutdown_tx),
        running,
    });
    Ok(())
}

#[cfg(not(feature = "shoes-backend"))]
fn stop_shoes_backend() {}

#[cfg(feature = "shoes-backend")]
fn running_snapshot(state_running: bool) -> bool {
    if let Some(handle) = shoes_handle().lock().unwrap().as_ref() {
        return handle.running.load(Ordering::SeqCst);
    }
    state_running
}

#[cfg(not(feature = "shoes-backend"))]
fn running_snapshot(state_running: bool) -> bool {
    state_running
}

#[cfg(feature = "shoes-backend")]
#[allow(dead_code)]
fn restart_backend_from_state(guard: &CoreState) -> Result<(), String> {
    if guard.tun_fd <= 0 {
        return Err("missing active TUN fd".to_string());
    }
    let rules = effective_rules(guard.connection_mode, &guard.groups, &guard.rules);
    let shoes_yaml = build_shoes_tun_config_with_runtime(
        guard.tun_fd,
        &guard.groups,
        &guard.proxies,
        &rules,
        &guard.runtime_config,
    )?;
    start_shoes_backend(shoes_yaml, guard.dns_config.clone())
}

#[cfg(not(feature = "shoes-backend"))]
#[allow(dead_code)]
fn restart_backend_from_state(_guard: &CoreState) -> Result<(), String> {
    Err("embedded shoes backend is not linked".to_string())
}

#[allow(dead_code)]
fn tcp_delay_ms(proxy: &ProxyNode, timeout_ms: i32) -> Result<i32, i32> {
    let server = proxy_field(proxy, "server");
    let port = proxy_field(proxy, "port");
    if server.is_empty() || port.is_empty() {
        return Err(-4);
    }
    let timeout = Duration::from_millis(timeout_ms.max(1) as u64);
    let address = format!("{server}:{port}");
    let mut addrs = address.to_socket_addrs().map_err(|_| -5)?;
    let Some(addr) = addrs.next() else {
        return Err(-5);
    };
    let start = Instant::now();
    TcpStream::connect_timeout(&addr, timeout).map_err(|_| -6)?;
    Ok(start.elapsed().as_millis().min(i32::MAX as u128) as i32)
}

struct DelayUrlTarget {
    scheme: String,
    host: String,
    port: u16,
    path_and_query: String,
}

fn parse_delay_url_target(url: &str) -> Result<DelayUrlTarget, i32> {
    let normalized = if url.trim().is_empty() {
        "https://www.gstatic.com/generate_204"
    } else {
        url.trim()
    };
    let (scheme, rest) = normalized
        .split_once("://")
        .ok_or(-7)
        .map(|(scheme, rest)| (scheme.to_ascii_lowercase(), rest))?;
    let authority_end = rest
        .find(|ch| matches!(ch, '/' | '?' | '#'))
        .unwrap_or(rest.len());
    let mut authority = &rest[..authority_end];
    let path_and_query = if authority_end < rest.len() {
        let suffix = &rest[authority_end..];
        if suffix.starts_with('?') {
            format!("/{suffix}")
        } else if suffix.starts_with('#') {
            "/".to_string()
        } else {
            let without_fragment = suffix.split('#').next().unwrap_or("/");
            if without_fragment.is_empty() {
                "/".to_string()
            } else {
                without_fragment.to_string()
            }
        }
    } else {
        "/".to_string()
    };
    if let Some((_, host_part)) = authority.rsplit_once('@') {
        authority = host_part;
    }
    if authority.is_empty() {
        return Err(-7);
    }
    let default_port = match scheme.as_str() {
        "https" => 443,
        "http" => 80,
        _ => return Err(-7),
    };

    if let Some(stripped) = authority.strip_prefix('[') {
        let Some(end) = stripped.find(']') else {
            return Err(-7);
        };
        let host = &stripped[..end];
        let rest = &stripped[end + 1..];
        let port = if let Some(port) = rest.strip_prefix(':') {
            port.parse::<u16>().map_err(|_| -7)?
        } else if rest.is_empty() {
            default_port
        } else {
            return Err(-7);
        };
        if host.is_empty() {
            return Err(-7);
        }
        return Ok(DelayUrlTarget {
            scheme,
            host: host.to_string(),
            port,
            path_and_query,
        });
    }

    let (host, port) = if let Some((host, port)) = authority.rsplit_once(':') {
        if host.contains(':') {
            (authority, default_port)
        } else {
            (host, port.parse::<u16>().map_err(|_| -7)?)
        }
    } else {
        (authority, default_port)
    };
    if host.is_empty() {
        return Err(-7);
    }
    Ok(DelayUrlTarget {
        scheme,
        host: host.to_string(),
        port,
        path_and_query,
    })
}

#[cfg(feature = "shoes-backend")]
fn proxy_delay_ms(proxy: &ProxyNode, url: &str, timeout_ms: i32) -> Result<i32, i32> {
    let target = parse_delay_url_target(url)?;
    let client_group_yaml = build_probe_client_group(proxy).map_err(|_| -8)?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| -9)?;
    let elapsed = runtime
        .block_on(shoes::probe::http_url_test_delay_ms(
            &client_group_yaml,
            "__clashhm_probe",
            &target.scheme,
            &target.host,
            target.port,
            &target.path_and_query,
            timeout_ms.max(1) as u64,
        ))
        .map_err(|_| -6)?;
    Ok(elapsed.min(i32::MAX as u128) as i32)
}

#[cfg(not(feature = "shoes-backend"))]
fn proxy_delay_ms(proxy: &ProxyNode, _url: &str, timeout_ms: i32) -> Result<i32, i32> {
    tcp_delay_ms(proxy, timeout_ms)
}

fn proxies_json(
    groups: &[ProxyGroup],
    proxies: &[ProxyNode],
    delay_by_proxy: &BTreeMap<String, i32>,
) -> String {
    let mut out = String::from("[");
    for (idx, group) in groups.iter().enumerate() {
        if idx > 0 {
            out.push(',');
        }
        out.push_str(&format!(
            "{{\"name\":\"{}\",\"type\":\"{}\",\"now\":\"{}\",\"all\":[",
            json_escape(&group.name),
            json_escape(&group.group_type),
            json_escape(&group.now)
        ));
        for (name_idx, name) in group.all.iter().enumerate() {
            if name_idx > 0 {
                out.push(',');
            }
            out.push_str(&format!("\"{}\"", json_escape(name)));
        }
        out.push_str("],\"nodes\":[");
        let mut node_count = 0;
        for proxy_name in &group.all {
            if let Some(proxy) = proxies.iter().find(|item| item.name == *proxy_name) {
                if node_count > 0 {
                    out.push(',');
                }
                node_count += 1;
                let latency = delay_by_proxy.get(&proxy.name).copied().unwrap_or(-1);
                let alive = latency != 0;
                out.push_str(&format!(
                    "{{\"name\":\"{}\",\"type\":\"{}\",\"alive\":{},\"latency\":{}}}",
                    json_escape(&proxy.name),
                    json_escape(&proxy.proxy_type),
                    if alive { "true" } else { "false" },
                    latency
                ));
            }
        }
        out.push_str("]}");
    }
    out.push(']');
    out
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_init(home_dir: *const c_char) -> c_int {
    let Ok(home) = cstr_to_string(home_dir) else {
        return -1;
    };
    let mut guard = state().lock().unwrap();
    guard.home_dir = home;
    guard.status = "initialized".to_string();
    guard.engine = "native-core".to_string();
    guard.last_error.clear();
    0
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_start_tun(
    tun_fd: c_int,
    clash_config: *const c_char,
) -> c_int {
    if tun_fd <= 0 {
        return -10;
    }
    let Ok(config) = cstr_to_string(clash_config) else {
        return -1;
    };
    let (proxies, groups, rules) = parse_clash_config(&config);
    let dns_config = parse_clash_dns_config(&config);
    let runtime_config = parse_runtime_config(&config);
    let connection_mode = parse_connection_mode(&config);
    let effective = effective_rules(connection_mode, &groups, &rules);
    let shoes_config = if proxies.is_empty() && groups.is_empty() && !rules.is_empty() {
        Err(format!(
            "no proxies or proxy-groups parsed from Clash config; parserVersion={}; rules={}; has_proxy_providers={}; has_proxies_section={}; has_proxy_groups_section={}; proxiesSample={}; groupsSample={}",
            PARSER_VERSION,
            rules.len(),
            config.contains("\nproxy-providers:") || config.starts_with("proxy-providers:"),
            config.contains("\nproxies:") || config.starts_with("proxies:"),
            config.contains("\nproxy-groups:") || config.starts_with("proxy-groups:"),
            json_escape(&section_sample(&config, "proxies:")),
            json_escape(&section_sample(&config, "proxy-groups:"))
        ))
    } else {
        build_shoes_tun_config_with_runtime(tun_fd, &groups, &proxies, &effective, &runtime_config)
    };
    let mut guard = state().lock().unwrap();
    guard.tun_fd = tun_fd;
    guard.proxies = proxies;
    guard.groups = groups;
    guard.rules = rules;
    guard.dns_config = dns_config.clone();
    guard.runtime_config = runtime_config;
    guard.connection_mode = connection_mode;
    guard.delay_by_proxy.clear();
    guard.running = false;
    guard.last_traffic_at_ms = now_ms();
    guard.last_upload_total = 0;
    guard.last_download_total = 0;
    guard.engine = if cfg!(feature = "shoes-backend") {
        "shoes"
    } else {
        "adapter-only"
    }
    .to_string();
    guard.last_error.clear();
    match shoes_config {
        Ok(shoes_yaml) => {
            #[cfg(feature = "shoes-backend")]
            {
                match start_shoes_backend(shoes_yaml, dns_config) {
                    Ok(()) => {
                        guard.running = true;
                        guard.status = "shoes_backend_started".to_string();
                        guard.started_at_ms = now_ms();
                        0
                    }
                    Err(error) => {
                        guard.status = format!("shoes_backend_error: {error}");
                        guard.last_error = error;
                        -101
                    }
                }
            }
            #[cfg(not(feature = "shoes-backend"))]
            {
                let _ = shoes_yaml;
                guard.status = "adapter_ready_core_backend_not_embedded".to_string();
                guard.last_error = "embedded shoes backend is not linked".to_string();
                -100
            }
        }
        Err(error) => {
            guard.status = format!("config_adapter_error: {error}");
            guard.last_error = error;
            -102
        }
    }
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_stop() -> c_int {
    stop_shoes_backend();
    let mut guard = state().lock().unwrap();
    guard.running = false;
    guard.tun_fd = -1;
    guard.status = "stopped".to_string();
    guard.started_at_ms = 0;
    0
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_is_running() -> c_int {
    #[cfg(feature = "shoes-backend")]
    {
        if let Some(handle) = shoes_handle().lock().unwrap().as_ref() {
            if handle.running.load(Ordering::SeqCst) {
                return 1;
            }
        }
    }
    let guard = state().lock().unwrap();
    if guard.running {
        1
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_load_config(clash_config: *const c_char) -> c_int {
    let Ok(config) = cstr_to_string(clash_config) else {
        return -1;
    };
    let (proxies, groups, rules) = parse_clash_config(&config);
    if proxies.is_empty() || groups.is_empty() {
        return -2;
    }
    let mut guard = state().lock().unwrap();
    guard.proxies = proxies;
    guard.groups = groups;
    guard.rules = rules;
    guard.connection_mode = parse_connection_mode(&config);
    guard.delay_by_proxy.clear();
    guard.status = "config_loaded_for_latency".to_string();
    guard.last_error.clear();
    0
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_get_proxies_json() -> *mut c_char {
    let guard = state().lock().unwrap();
    into_c_string(proxies_json(
        &guard.groups,
        &guard.proxies,
        &guard.delay_by_proxy,
    ))
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_parse_proxies_json(
    clash_config: *const c_char,
) -> *mut c_char {
    let Ok(config) = cstr_to_string(clash_config) else {
        return into_c_string("[]".to_string());
    };
    let (proxies, groups, _rules) = parse_clash_config(&config);
    let delays = BTreeMap::new();
    into_c_string(proxies_json(&groups, &proxies, &delays))
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_select_proxy(
    group_name: *const c_char,
    proxy_name: *const c_char,
) -> c_int {
    let Ok(group_name) = cstr_to_string(group_name) else {
        return -1;
    };
    let Ok(proxy_name) = cstr_to_string(proxy_name) else {
        return -1;
    };
    let mut guard = state().lock().unwrap();
    let Some(group_index) = guard
        .groups
        .iter()
        .position(|group| group.name == group_name)
    else {
        return -2;
    };
    if !guard.groups[group_index]
        .all
        .iter()
        .any(|name| name == &proxy_name)
    {
        return -3;
    }

    guard.groups[group_index].now = proxy_name;
    let should_restart = guard.running && guard.tun_fd > 0;
    if should_restart {
        match restart_backend_from_state(&guard) {
            Ok(()) => {
                guard.status = "selection_applied_backend_restarted".to_string();
                guard.started_at_ms = now_ms();
                guard.last_error.clear();
                0
            }
            Err(error) => {
                guard.status = format!("selection_restart_error: {error}");
                guard.last_error = error;
                -4
            }
        }
    } else {
        guard.status = "selection_applied_pending_start".to_string();
        guard.last_error.clear();
        0
    }
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_set_mode(mode: *const c_char) -> c_int {
    let Ok(mode) = cstr_to_string(mode) else {
        return -1;
    };
    let mut guard = state().lock().unwrap();
    guard.connection_mode = parse_connection_mode_text(&mode);
    let should_restart = guard.running && guard.tun_fd > 0;
    if should_restart {
        match restart_backend_from_state(&guard) {
            Ok(()) => {
                guard.status = "mode_applied_backend_restarted".to_string();
                guard.started_at_ms = now_ms();
                guard.last_error.clear();
                0
            }
            Err(error) => {
                guard.status = format!("mode_restart_error: {error}");
                guard.last_error = error;
                -2
            }
        }
    } else {
        guard.status = "mode_applied_pending_start".to_string();
        guard.last_error.clear();
        0
    }
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_test_delay(
    proxy_name: *const c_char,
    url: *const c_char,
    timeout_ms: c_int,
) -> c_int {
    let Ok(proxy_name) = cstr_to_string(proxy_name) else {
        return -1;
    };
    let url = cstr_to_string(url).unwrap_or_default();
    let guard = state().lock().unwrap();
    let proxy = if proxy_name.is_empty() {
        selected_proxy(&guard.groups, &guard.proxies)
    } else {
        guard.proxies.iter().find(|item| item.name == proxy_name)
    };
    let Some(proxy) = proxy else {
        return -2;
    };
    let tested_proxy_name = proxy.name.clone();
    let tested_proxy = proxy.clone();
    drop(guard);
    let result = proxy_delay_ms(&tested_proxy, &url, timeout_ms).unwrap_or_else(|code| code);
    let mut guard = state().lock().unwrap();
    guard.last_delay_ms = result;
    guard.delay_by_proxy.insert(tested_proxy_name, result);
    let delay_by_proxy = guard.delay_by_proxy.clone();
    update_auto_group_selection(&mut guard.groups, &delay_by_proxy);
    result
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_get_traffic_json() -> *mut c_char {
    #[cfg(feature = "shoes-backend")]
    let (upload_total, download_total) = shoes::tun::traffic_snapshot();
    #[cfg(not(feature = "shoes-backend"))]
    let (upload_total, download_total) = (0u64, 0u64);
    let now = now_ms();
    let mut guard = state().lock().unwrap();
    let elapsed_ms = now.saturating_sub(guard.last_traffic_at_ms);
    let upload_delta = upload_total.saturating_sub(guard.last_upload_total);
    let download_delta = download_total.saturating_sub(guard.last_download_total);
    let upload_speed = if elapsed_ms > 0 {
        upload_delta.saturating_mul(1000) / elapsed_ms as u64
    } else {
        0
    };
    let download_speed = if elapsed_ms > 0 {
        download_delta.saturating_mul(1000) / elapsed_ms as u64
    } else {
        0
    };
    guard.last_traffic_at_ms = now;
    guard.last_upload_total = upload_total;
    guard.last_download_total = download_total;
    drop(guard);
    into_c_string(format!(
        "{{\"uploadSpeed\":{},\"downloadSpeed\":{},\"uploadTotal\":{},\"downloadTotal\":{}}}",
        upload_speed, download_speed, upload_total, download_total
    ))
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_get_status_json() -> *mut c_char {
    let guard = state().lock().unwrap();
    let running = running_snapshot(guard.running);
    let selected_group = selected_group(&guard.groups);
    let selected_group_name = selected_group
        .map(|group| group.name.as_str())
        .unwrap_or("");
    let selected_proxy_name = selected_group
        .map(|group| {
            if group.now.is_empty() {
                group.all.first().map(String::as_str).unwrap_or("")
            } else {
                group.now.as_str()
            }
        })
        .unwrap_or("");
    let selected_proxy = guard
        .proxies
        .iter()
        .find(|proxy| proxy.name == selected_proxy_name);
    let selected_proxy_type = selected_proxy
        .map(|proxy| proxy.proxy_type.as_str())
        .unwrap_or("");
    let selected_proxy_server = selected_proxy
        .map(|proxy| proxy_field(proxy, "server"))
        .unwrap_or("");
    let skipped_types = skipped_rule_types(&guard.rules);
    let skipped_count = skipped_rule_count(&guard.rules);
    #[cfg(feature = "shoes-backend")]
    let route_debug = shoes::tun::route_debug_json();
    #[cfg(not(feature = "shoes-backend"))]
    let route_debug = "{}".to_string();
    let uptime_ms = if running && guard.started_at_ms > 0 {
        now_ms().saturating_sub(guard.started_at_ms)
    } else {
        0
    };
    let tls_client_mode = match guard.runtime_config.tls_client_mode {
        TlsClientMode::Chrome => "chrome",
        TlsClientMode::Rustls => "rustls",
    };
    into_c_string(format!(
        "{{\"running\":{},\"engine\":\"{}\",\"tunFd\":{},\"status\":\"{}\",\"lastError\":\"{}\",\"selectedGroup\":\"{}\",\"selectedProxy\":\"{}\",\"selectedProxyType\":\"{}\",\"selectedProxyServer\":\"{}\",\"proxyCount\":{},\"groupCount\":{},\"ruleCount\":{},\"skippedRuleCount\":{},\"skippedRuleTypes\":{},\"routeDebug\":{},\"uptimeMs\":{},\"lastDelayMs\":{},\"tlsClientMode\":\"{}\",\"connectionMode\":\"{}\",\"parserVersion\":\"{}\"}}",
        if running { "true" } else { "false" },
        json_escape(&guard.engine),
        guard.tun_fd,
        json_escape(&guard.status),
        json_escape(&guard.last_error),
        json_escape(selected_group_name),
        json_escape(selected_proxy_name),
        json_escape(selected_proxy_type),
        json_escape(selected_proxy_server),
        guard.proxies.len(),
        guard.groups.len(),
        guard.rules.len(),
        skipped_count,
        json_string_array(&skipped_types),
        route_debug,
        uptime_ms,
        guard.last_delay_ms,
        tls_client_mode,
        guard.connection_mode.as_str(),
        json_escape(PARSER_VERSION)
    ))
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_get_connections_json() -> *mut c_char {
    into_c_string("[]".to_string())
}

#[no_mangle]
pub extern "C" fn clashhm_native_core_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_clash_groups() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: secret }
  - name: B
    type: trojan
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - A
      - B
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        assert_eq!(proxies.len(), 2);
        assert_eq!(groups.len(), 1);
        assert_eq!(rules.len(), 0);
        assert_eq!(groups[0].now, "A");
        assert_eq!(groups[0].all, vec!["A".to_string(), "B".to_string()]);
    }

    #[test]
    fn parses_flow_proxy_group_list_without_truncating_at_commas() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: a.example.com, port: 443, cipher: aes-128-gcm, password: secret-a }
  - { name: B, type: ss, server: b.example.com, port: 443, cipher: aes-128-gcm, password: secret-b }
proxy-groups:
  - { name: Proxy, type: select, proxies: [A, B, DIRECT] }
rules:
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        assert_eq!(proxies.len(), 2);
        assert_eq!(rules.len(), 1);
        assert_eq!(
            groups[0].all,
            vec!["A".to_string(), "B".to_string(), "DIRECT".to_string()]
        );
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("address: \"a.example.com:443\""));
    }

    #[test]
    fn expands_yaml_proxy_provider_use_entries() {
        let config = r#"
proxy-providers:
  hk:
    type: file
    path: ./hk.yaml
    proxies:
      - name: HK 1
        type: ss
        server: hk1.example.com
        port: 443
        cipher: aes-128-gcm
        password: secret
      - name: HK 2
        type: ss
        server: hk2.example.com
        port: 443
        cipher: aes-128-gcm
        password: secret
proxy-groups:
  - name: Proxy
    type: select
    use:
      - hk
rules:
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        assert_eq!(proxies.len(), 2);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].all, vec!["HK 1".to_string(), "HK 2".to_string()]);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("address: \"hk1.example.com:443\""));
    }

    #[test]
    fn expands_yaml_rule_provider_rule_set_entries() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - A
rule-providers:
  private:
    type: inline
    behavior: domain
    payload:
      - +.example.com
      - test.local
rules:
  - RULE-SET,private,DIRECT
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "DOMAIN-SUFFIX" && rule.payload == "example.com"));
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "DOMAIN-SUFFIX" && rule.payload == "test.local"));
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("masks: \"example.com\""));
        assert!(shoes_config.contains("masks: \"test.local\""));
    }

    #[test]
    fn expands_mihomo_style_rule_provider_entries() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - A
rule-providers:
  domains:
    type: inline
    behavior: domain
    payload:
      - +.suffix.example.com
      - DOMAIN,exact.example.com
      - DOMAIN-KEYWORD,needle
      - domain:prefixed.example.com
      - full:full.example.com
      - keyword:ads
  cidrs:
    type: inline
    behavior: ipcidr
    payload:
      - 192.0.2.0/24
      - IP-CIDR6,2001:db8::/32
  classical:
    type: inline
    behavior: classical
    payload:
      - GEOIP,CN
      - GEOSITE,google
      - DOMAIN-KEYWORD,youtube
rules:
  - RULE-SET,domains,DIRECT
  - RULE-SET,cidrs,DIRECT
  - RULE-SET,classical,Proxy
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "DOMAIN-SUFFIX" && rule.payload == "suffix.example.com"));
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "DOMAIN" && rule.payload == "exact.example.com"));
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "DOMAIN-KEYWORD" && rule.payload == "needle"));
        assert!(rules.iter().any(
            |rule| rule.rule_type == "DOMAIN-SUFFIX" && rule.payload == "prefixed.example.com"
        ));
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "DOMAIN" && rule.payload == "full.example.com"));
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "DOMAIN-KEYWORD" && rule.payload == "ads"));
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "IP-CIDR" && rule.payload == "192.0.2.0/24"));
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "IP-CIDR6" && rule.payload == "2001:db8::/32"));
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "GEOIP" && rule.payload == "CN"));
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "GEOSITE" && rule.payload == "google"));
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("masks: \"suffix.example.com\""));
        assert!(shoes_config.contains("masks: \"exact.example.com\""));
        assert!(shoes_config.contains("domain_keywords: \"needle\""));
        assert!(shoes_config.contains("domain_keywords: \"ads\""));
        assert!(shoes_config.contains("masks: \"192.0.2.0/24\""));
        assert!(shoes_config.contains("geoip_countries: \"CN\""));
        assert!(shoes_config.contains("\"google.com\""));
    }

    #[test]
    fn expands_inline_flow_rule_provider_payloads() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - { name: Proxy, type: select, proxies: [A] }
rule-providers:
  flow:
    type: inline
    behavior: classical
    payload: ["DOMAIN-SUFFIX,flow.example.com", "DOMAIN-KEYWORD,flow-keyword"]
  single:
    type: inline
    behavior: domain
    rules: full:single.example.com
rules:
  - RULE-SET,flow,DIRECT
  - RULE-SET,single,DIRECT
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "DOMAIN-SUFFIX" && rule.payload == "flow.example.com"));
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "DOMAIN-KEYWORD" && rule.payload == "flow-keyword"));
        assert!(rules
            .iter()
            .any(|rule| rule.rule_type == "DOMAIN" && rule.payload == "single.example.com"));
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("masks: \"flow.example.com\""));
        assert!(shoes_config.contains("domain_keywords: \"flow-keyword\""));
        assert!(shoes_config.contains("masks: \"single.example.com\""));
    }

    #[test]
    fn builds_shoes_config_for_selected_shadowsocks() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - A
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("device_fd: 28"));
        assert!(shoes_config.contains("type: shadowsocks"));
        assert!(shoes_config.contains("address: \"example.com:443\""));
        assert!(shoes_config.contains("cipher: \"aes-128-gcm\""));
    }

    #[test]
    fn builds_rule_based_shoes_config() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - A
rules:
  - DOMAIN-KEYWORD,google,Proxy
  - DOMAIN-SUFFIX,example.com,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("masks: \"example.com\""));
        assert!(shoes_config.contains("masks: \"10.0.0.0/8\""));
        assert!(shoes_config.contains("masks: \"0.0.0.0/0\""));
        assert!(shoes_config.contains("type: direct"));
        assert!(shoes_config.contains("address: \"proxy.example.com:443\""));
    }

    #[test]
    fn maps_geoip_country_rules_and_uses_match_fallback() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - A
rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("geoip_countries: \"CN\""));
        assert!(shoes_config.contains("masks: \"0.0.0.0/0\""));
        assert!(shoes_config.contains("address: \"proxy.example.com:443\""));
    }

    #[test]
    fn maps_basic_geoip_private_and_geosite_cn_rules() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - A
rules:
  - GEOIP,PRIVATE,DIRECT
  - GEOSITE,cn,DIRECT
  - GEOSITE,private,DIRECT
  - GEOSITE,local,DIRECT
  - GEOSITE,lan,DIRECT
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("masks: \"10.0.0.0/8\""));
        assert!(shoes_config.contains("masks: \"192.168.0.0/16\""));
        assert!(shoes_config.contains("masks:"));
        assert!(shoes_config.contains("\"localhost\""));
        assert!(shoes_config.contains("\"local\""));
        assert!(shoes_config.contains("\"lan\""));
        assert!(shoes_config.contains("\"home.arpa\""));
        assert!(shoes_config.contains("type: direct"));
        assert!(shoes_config.contains("address: \"proxy.example.com:443\""));
    }

    #[cfg(feature = "shoes-backend")]
    #[test]
    fn maps_dat_backed_geosite_rules() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - A
rules:
  - GEOSITE,geolocation-cn,DIRECT
  - GEOSITE,google,Proxy
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("\"0033.cn\""), "{shoes_config}");
        assert!(shoes_config.contains("\"google.com\""), "{shoes_config}");
        assert!(
            shoes::config::load_config_str(&shoes_config).is_ok(),
            "{shoes_config}"
        );
    }

    #[test]
    fn url_test_group_selects_lowest_cached_delay() {
        let mut groups = vec![ProxyGroup {
            name: "Auto".to_string(),
            group_type: "url-test".to_string(),
            now: "A".to_string(),
            all: vec!["A".to_string(), "B".to_string(), "C".to_string()],
        }];
        let mut delays = BTreeMap::new();
        delays.insert("A".to_string(), 300);
        delays.insert("B".to_string(), 90);
        delays.insert("C".to_string(), 0);

        update_auto_group_selection(&mut groups, &delays);

        assert_eq!(groups[0].now, "B");
    }

    #[test]
    fn fallback_group_selects_first_available_cached_delay() {
        let mut groups = vec![ProxyGroup {
            name: "Fallback".to_string(),
            group_type: "fallback".to_string(),
            now: "A".to_string(),
            all: vec!["A".to_string(), "B".to_string(), "C".to_string()],
        }];
        let mut delays = BTreeMap::new();
        delays.insert("A".to_string(), 0);
        delays.insert("B".to_string(), 120);
        delays.insert("C".to_string(), 80);

        update_auto_group_selection(&mut groups, &delays);

        assert_eq!(groups[0].now, "B");
    }

    #[test]
    fn parses_delay_url_target_defaults_and_ports() {
        let default_target = parse_delay_url_target("").unwrap();
        assert_eq!(default_target.scheme, "https");
        assert_eq!(default_target.host, "www.gstatic.com");
        assert_eq!(default_target.port, 443);
        assert_eq!(default_target.path_and_query, "/generate_204");

        let https_target = parse_delay_url_target("https://www.gstatic.com/generate_204").unwrap();
        assert_eq!(https_target.host, "www.gstatic.com");
        assert_eq!(https_target.port, 443);
        assert_eq!(https_target.path_and_query, "/generate_204");

        let http_target = parse_delay_url_target("http://example.com:8080/path?q=1#frag").unwrap();
        assert_eq!(http_target.scheme, "http");
        assert_eq!(http_target.host, "example.com");
        assert_eq!(http_target.port, 8080);
        assert_eq!(http_target.path_and_query, "/path?q=1");

        let ipv6_target = parse_delay_url_target("https://[2001:db8::1]/").unwrap();
        assert_eq!(ipv6_target.host, "2001:db8::1");
        assert_eq!(ipv6_target.port, 443);
        assert_eq!(ipv6_target.path_and_query, "/");
    }

    #[cfg(feature = "shoes-backend")]
    #[test]
    fn builds_probe_client_group_yaml() {
        let mut fields = BTreeMap::new();
        fields.insert("server".to_string(), "127.0.0.1".to_string());
        fields.insert("port".to_string(), "1080".to_string());
        let proxy = ProxyNode {
            name: "Socks".to_string(),
            proxy_type: "socks5".to_string(),
            fields,
        };
        let yaml = build_probe_client_group(&proxy).unwrap();
        assert!(shoes::config::load_config_str(&yaml).is_ok(), "{yaml}");
    }

    #[test]
    fn proxy_json_reports_cached_latency() {
        let proxies = vec![ProxyNode {
            name: "A".to_string(),
            proxy_type: "ss".to_string(),
            fields: BTreeMap::new(),
        }];
        let groups = vec![ProxyGroup {
            name: "Proxy".to_string(),
            group_type: "select".to_string(),
            now: "A".to_string(),
            all: vec!["A".to_string()],
        }];
        let mut delays = BTreeMap::new();
        delays.insert("A".to_string(), 123);

        let json = proxies_json(&groups, &proxies, &delays);

        assert!(json.contains("\"latency\":123"), "{json}");
        assert!(json.contains("\"alive\":true"), "{json}");
    }

    #[test]
    fn load_config_populates_state_without_starting_tun() {
        let config = CString::new(
            r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - A
rules:
  - MATCH,Proxy
"#,
        )
        .unwrap();

        assert_eq!(clashhm_native_core_load_config(config.as_ptr()), 0);
        assert_eq!(clashhm_native_core_is_running(), 0);
        let proxies_ptr = clashhm_native_core_get_proxies_json();
        let proxies = unsafe { CStr::from_ptr(proxies_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        clashhm_native_core_free_string(proxies_ptr);

        assert!(proxies.contains("\"name\":\"Proxy\""), "{proxies}");
        assert!(proxies.contains("\"name\":\"A\""), "{proxies}");
    }

    #[test]
    fn generated_hysteria2_config_is_parseable_by_shoes() {
        let config = r#"
proxies:
  - { name: HY2, type: hysteria2, server: hy.example.com, port: 443, password: secret, sni: hy-sni.example.com, skip-cert-verify: true, alpn: h3 }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - HY2
rules:
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let result = build_shoes_tun_config(28, &groups, &proxies, &rules);
        assert!(result.is_ok(), "{result:?}");
        let yaml = result.unwrap();
        assert!(yaml.contains("type: hysteria2"), "{yaml}");
        assert!(yaml.contains("transport: quic"), "{yaml}");
        assert!(yaml.contains("verify: false"), "{yaml}");
        assert!(
            yaml.contains("sni_hostname: \"hy-sni.example.com\""),
            "{yaml}"
        );
        assert!(yaml.contains("alpn_protocols: \"h3\""), "{yaml}");
        #[cfg(feature = "shoes-backend")]
        assert!(shoes::config::load_config_str(&yaml).is_ok(), "{yaml}");
    }

    #[test]
    fn generated_tuic_config_is_parseable_by_shoes() {
        let config = r#"
proxies:
  - { name: TUIC, type: tuic, server: tuic.example.com, port: 443, uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0, password: secret, sni: tuic-sni.example.com, skip-cert-verify: true, alpn: h3 }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - TUIC
rules:
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let result = build_shoes_tun_config(28, &groups, &proxies, &rules);
        assert!(result.is_ok(), "{result:?}");
        let yaml = result.unwrap();
        assert!(yaml.contains("type: tuic"), "{yaml}");
        assert!(yaml.contains("transport: quic"), "{yaml}");
        assert!(yaml.contains("verify: false"), "{yaml}");
        assert!(
            yaml.contains("sni_hostname: \"tuic-sni.example.com\""),
            "{yaml}"
        );
        assert!(yaml.contains("alpn_protocols: \"h3\""), "{yaml}");
        #[cfg(feature = "shoes-backend")]
        assert!(shoes::config::load_config_str(&yaml).is_ok(), "{yaml}");
    }

    #[test]
    fn maps_hysteria2_auth_alias_and_rejects_unsupported_obfs() {
        let config = r#"
proxies:
  - { name: HY2, type: hy2, server: hy.example.com, port: 443, auth-str: secret }
proxy-groups:
  - { name: Proxy, type: select, proxies: [HY2] }
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let yaml = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(yaml.contains("type: hysteria2"), "{yaml}");
        assert!(yaml.contains("password: \"secret\""), "{yaml}");
        #[cfg(feature = "shoes-backend")]
        assert!(shoes::config::load_config_str(&yaml).is_ok(), "{yaml}");

        let unsupported = r#"
proxies:
  - { name: HY2, type: hy2, server: hy.example.com, port: 443, auth: secret, obfs: salamander, obfs-password: obfs-secret }
proxy-groups:
  - { name: Proxy, type: select, proxies: [HY2] }
"#;
        let (proxies, groups, rules) = parse_clash_config(unsupported);
        let error = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap_err();
        assert!(error.contains("uses obfs"), "{error}");
    }

    #[test]
    fn maps_tuic_token_alias_and_reports_unsupported_congestion() {
        let config = r#"
proxies:
  - { name: TUIC, type: tuic, server: tuic.example.com, port: 443, uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0, token: secret }
proxy-groups:
  - { name: Proxy, type: select, proxies: [TUIC] }
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let yaml = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(yaml.contains("type: tuic"), "{yaml}");
        assert!(yaml.contains("password: \"secret\""), "{yaml}");
        #[cfg(feature = "shoes-backend")]
        assert!(shoes::config::load_config_str(&yaml).is_ok(), "{yaml}");

        let unsupported = r#"
proxies:
  - { name: TUIC, type: tuic, server: tuic.example.com, port: 443, uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0, password: secret, congestion-controller: cubic }
proxy-groups:
  - { name: Proxy, type: select, proxies: [TUIC] }
"#;
        let (proxies, groups, rules) = parse_clash_config(unsupported);
        let error = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap_err();
        assert!(error.contains("congestion-controller cubic"), "{error}");
    }

    #[test]
    fn parses_block_style_hysteria2_and_tuic_aliases() {
        let config = r#"
proxies:
  - name: HY2 Block
    type: hysteria2
    server: hy.example.com
    port: 443
    auth: hy-secret
    disable-sni: false
  - name: TUIC Block
    type: tuic
    server: tuic.example.com
    port: 443
    uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0
    token: tuic-secret
    congestion-controller: bbr
proxy-groups:
  - name: HY2 Proxy
    type: select
    proxies:
      - HY2 Block
  - name: TUIC Proxy
    type: select
    proxies:
      - TUIC Block
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let hy2_group = vec![groups
            .iter()
            .find(|group| group.name == "HY2 Proxy")
            .unwrap()
            .clone()];
        let tuic_group = vec![groups
            .iter()
            .find(|group| group.name == "TUIC Proxy")
            .unwrap()
            .clone()];

        let hy2_yaml = build_shoes_tun_config(28, &hy2_group, &proxies, &rules).unwrap();
        assert!(hy2_yaml.contains("type: hysteria2"), "{hy2_yaml}");
        assert!(hy2_yaml.contains("password: \"hy-secret\""), "{hy2_yaml}");

        let tuic_yaml = build_shoes_tun_config(28, &tuic_group, &proxies, &rules).unwrap();
        assert!(tuic_yaml.contains("type: tuic"), "{tuic_yaml}");
        assert!(
            tuic_yaml.contains("password: \"tuic-secret\""),
            "{tuic_yaml}"
        );

        #[cfg(feature = "shoes-backend")]
        {
            assert!(
                shoes::config::load_config_str(&hy2_yaml).is_ok(),
                "{hy2_yaml}"
            );
            assert!(
                shoes::config::load_config_str(&tuic_yaml).is_ok(),
                "{tuic_yaml}"
            );
        }
    }

    #[test]
    fn resolves_group_selection_to_direct() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - DIRECT
      - A
rules:
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("masks: \"0.0.0.0/0\""));
        assert!(shoes_config.contains("type: direct"));
        assert!(!shoes_config.contains("address: \"proxy.example.com:443\""));
    }

    #[test]
    fn resolves_nested_group_selection() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Auto
    type: select
    proxies:
      - A
  - name: Proxy
    type: select
    proxies:
      - Auto
      - DIRECT
rules:
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("address: \"proxy.example.com:443\""));
    }

    #[test]
    fn builds_wrapped_vmess_websocket_tls_config() {
        let config = r#"
proxies:
  - { name: VMess WS, type: vmess, server: example.com, port: 443, uuid: b0e80a62-8a51-47f0-91f1-f0f7faf8d9d4, cipher: auto, tls: true, network: ws, path: /ws, servername: example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - VMess WS
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: tls"));
        assert!(shoes_config.contains("type: ws"));
        assert!(shoes_config.contains("matching_path: \"/ws\""));
        assert!(shoes_config.contains("type: vmess"));
    }

    #[test]
    fn builds_vmess_h2mux_config_from_clash_mux() {
        let config = r#"
proxies:
  - name: VMess Mux
    type: vmess
    server: mux.example.com
    port: 443
    uuid: b0e80a62-8a51-47f0-91f1-f0f7faf8d9d4
    cipher: auto
    tls: true
    mux:
      enabled: true
      max-connections: 2
      min-streams: 3
      max-streams: 16
      padding: true
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - VMess Mux
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("h2mux:"));
        assert!(shoes_config.contains("max_connections: 2"));
        assert!(shoes_config.contains("min_streams: 3"));
        assert!(shoes_config.contains("max_streams: 16"));
        assert!(shoes_config.contains("padding: true"));
    }

    #[test]
    fn honors_udp_disabled_on_supported_proxy() {
        let config = r#"
proxies:
  - { name: SS No UDP, type: ss, server: ss.example.com, port: 443, cipher: aes-128-gcm, password: secret, udp: false }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - SS No UDP
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("udp_enabled: false"));
    }

    #[test]
    fn parses_block_websocket_opts_with_host_header() {
        let config = r#"
proxies:
  - name: VLESS WS
    type: vless
    server: ws.example.com
    port: 443
    uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0
    tls: true
    network: ws
    ws-opts:
      path: /vless
      headers:
        Host: cdn.example.com
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - VLESS WS
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: ws"));
        assert!(shoes_config.contains("matching_path: \"/vless\""));
        assert!(shoes_config.contains("matching_headers:"));
        assert!(shoes_config.contains("Host: \"cdn.example.com\""));
    }

    #[test]
    fn parses_flow_websocket_opts_with_host_header() {
        let config = r#"
proxies:
  - { name: VLESS WS, type: vless, server: ws.example.com, port: 443, uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0, tls: true, network: ws, ws-opts: { path: /flow, headers: { Host: edge.example.com } } }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - VLESS WS
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("matching_path: \"/flow\""));
        assert!(shoes_config.contains("Host: \"edge.example.com\""));
    }

    #[test]
    fn builds_reality_vless_config() {
        let config = r#"
proxies:
  - { name: Reality, type: vless, server: reality.example.com, port: 443, uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0, security: reality, pbk: SERVER_PUBLIC_KEY, sid: 0123456789abcdef, sni: www.cloudflare.com, flow: xtls-rprx-vision }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Reality
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: reality"));
        assert!(shoes_config.contains("public_key: \"SERVER_PUBLIC_KEY\""));
        assert!(shoes_config.contains("vision: true"));
        assert!(shoes_config.contains("type: vless"));
    }

    #[test]
    fn parses_block_reality_opts_config() {
        let config = r#"
proxies:
  - name: Reality
    type: vless
    server: reality.example.com
    port: 443
    uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0
    security: reality
    flow: xtls-rprx-vision
    reality-opts:
      public-key: SERVER_PUBLIC_KEY
      short-id: 0123456789abcdef
      server-name: www.cloudflare.com
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Reality
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: reality"));
        assert!(shoes_config.contains("public_key: \"SERVER_PUBLIC_KEY\""));
        assert!(shoes_config.contains("short_id: \"0123456789abcdef\""));
        assert!(shoes_config.contains("sni_hostname: \"www.cloudflare.com\""));
    }

    #[test]
    fn builds_grpc_transport_config() {
        let config = r#"
proxies:
  - name: VLESS GRPC
    type: vless
    server: grpc.example.com
    port: 443
    uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0
    tls: true
    network: grpc
    grpc-opts:
      serviceName: proxy
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - VLESS GRPC
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: tls"), "{shoes_config}");
        assert!(
            shoes_config.contains("alpn_protocols: \"h2\""),
            "{shoes_config}"
        );
        assert!(shoes_config.contains("type: grpc"), "{shoes_config}");
        assert!(
            shoes_config.contains("service_name: \"proxy\""),
            "{shoes_config}"
        );
        assert!(
            shoes_config.contains("authority: \"grpc.example.com\""),
            "{shoes_config}"
        );
    }

    #[test]
    fn builds_h2_transport_without_mapping_to_h2mux() {
        let config = r#"
proxies:
  - name: VLESS H2
    type: vless
    server: h2.example.com
    port: 443
    uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0
    tls: true
    network: h2
    h2-opts:
      path: /vless
      host:
        - cdn.example.com
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - VLESS H2
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: tls"), "{shoes_config}");
        assert!(
            shoes_config.contains("alpn_protocols: \"h2\""),
            "{shoes_config}"
        );
        assert!(shoes_config.contains("type: h2"), "{shoes_config}");
        assert!(shoes_config.contains("path: \"/vless\""), "{shoes_config}");
        assert!(
            shoes_config.contains("host: \"cdn.example.com\""),
            "{shoes_config}"
        );
        assert!(!shoes_config.contains("h2mux:"), "{shoes_config}");
    }

    #[test]
    fn builds_snell_config() {
        let config = r#"
proxies:
  - { name: Snell, type: snell, server: snell.example.com, port: 443, cipher: aes-128-gcm, password: secret, version: 3 }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Snell
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: snell"));
        assert!(shoes_config.contains("address: \"snell.example.com:443\""));
    }

    #[test]
    fn builds_anytls_config_with_tls_wrapper() {
        let config = r#"
proxies:
  - { name: AnyTLS, type: anytls, server: anytls.example.com, port: 443, password: secret, sni: anytls.example.com, skip-cert-verify: true }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - AnyTLS
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: tls"));
        assert!(shoes_config.contains("type: anytls"));
        assert!(shoes_config.contains("password: \"secret\""));
        assert!(shoes_config.contains("sni_hostname: \"anytls.example.com\""));
        assert!(shoes_config.contains("verify: false"));
    }

    #[test]
    fn chrome_trojan_with_fronting_sni_uses_compat_certificate_verification() {
        let config = r#"
proxies:
  - { name: Trojan, type: trojan, server: proxy.example.com, port: 443, password: secret, sni: front.example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Trojan
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: tls"), "{shoes_config}");
        assert!(
            shoes_config.contains("client_fingerprint: \"chrome\""),
            "{shoes_config}"
        );
        assert!(shoes_config.contains("verify: false"), "{shoes_config}");
    }

    #[test]
    fn chrome_trojan_with_matching_sni_keeps_strict_certificate_verification() {
        let config = r#"
proxies:
  - { name: Trojan, type: trojan, server: proxy.example.com, port: 443, password: secret, sni: proxy.example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Trojan
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: tls"), "{shoes_config}");
        assert!(
            shoes_config.contains("client_fingerprint: \"chrome\""),
            "{shoes_config}"
        );
        assert!(!shoes_config.contains("verify: false"), "{shoes_config}");
    }

    #[test]
    fn rustls_trojan_keeps_strict_certificate_verification_by_default() {
        let config = r#"
proxies:
  - { name: Trojan, type: trojan, server: proxy.example.com, port: 443, password: secret, sni: front.example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Trojan
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let runtime_config = RuntimeConfig {
            tls_client_mode: TlsClientMode::Rustls,
        };
        let shoes_config =
            build_shoes_tun_config_with_runtime(28, &groups, &proxies, &rules, &runtime_config)
                .unwrap();
        assert!(shoes_config.contains("type: tls"), "{shoes_config}");
        assert!(
            !shoes_config.contains("client_fingerprint:"),
            "{shoes_config}"
        );
        assert!(!shoes_config.contains("verify: false"), "{shoes_config}");
    }

    #[test]
    fn global_mode_routes_everything_to_selected_group() {
        let groups = vec![ProxyGroup {
            name: "Proxy".to_string(),
            group_type: "select".to_string(),
            now: "A".to_string(),
            all: vec!["A".to_string(), "B".to_string()],
        }];
        let rules = vec![ClashRule {
            rule_type: "DOMAIN-SUFFIX".to_string(),
            payload: "example.com".to_string(),
            target: "DIRECT".to_string(),
        }];

        let effective = effective_rules(ConnectionMode::Global, &groups, &rules);

        assert_eq!(effective.len(), 1);
        assert_eq!(effective[0].rule_type, "MATCH");
        assert_eq!(effective[0].target, "Proxy");
    }

    #[test]
    fn direct_mode_routes_everything_direct() {
        let groups = vec![ProxyGroup {
            name: "Proxy".to_string(),
            group_type: "select".to_string(),
            now: "A".to_string(),
            all: vec!["A".to_string()],
        }];
        let rules = vec![ClashRule {
            rule_type: "MATCH".to_string(),
            payload: String::new(),
            target: "Proxy".to_string(),
        }];

        let effective = effective_rules(ConnectionMode::Direct, &groups, &rules);

        assert_eq!(effective.len(), 1);
        assert_eq!(effective[0].rule_type, "MATCH");
        assert_eq!(effective[0].target, "DIRECT");
    }

    #[test]
    fn builds_naiveproxy_config_with_tls_and_h2() {
        let config = r#"
proxies:
  - { name: Naive, type: naive, server: naive.example.com, port: 443, username: user, password: secret, sni: naive.example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Naive
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: tls"));
        assert!(shoes_config.contains("alpn_protocols: \"h2\""));
        assert!(shoes_config.contains("type: naiveproxy"));
        assert!(shoes_config.contains("username: \"user\""));
        assert!(shoes_config.contains("password: \"secret\""));
    }

    #[test]
    fn builds_shadowtls_plugin_wrapper() {
        let config = r#"
proxies:
  - { name: SS ShadowTLS, type: ss, server: shadow.example.com, port: 443, cipher: aes-128-gcm, password: ss-secret, plugin: shadow-tls, shadow-tls-password: shadow-secret, shadow-tls-sni: www.example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - SS ShadowTLS
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: shadowtls"));
        assert!(shoes_config.contains("password: \"shadow-secret\""));
        assert!(shoes_config.contains("sni_hostname: \"www.example.com\""));
        assert!(shoes_config.contains("type: shadowsocks"));
        assert!(shoes_config.contains("password: \"ss-secret\""));
    }

    #[test]
    fn parses_shadowtls_plugin_opts_without_overwriting_proxy_password() {
        let config = r#"
proxies:
  - name: SS ShadowTLS
    type: ss
    server: shadow.example.com
    port: 443
    cipher: aes-128-gcm
    password: ss-secret
    plugin: shadow-tls
    plugin-opts:
      password: shadow-secret
      host: www.example.com
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - SS ShadowTLS
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: shadowtls"));
        assert!(shoes_config.contains("password: \"shadow-secret\""));
        assert!(shoes_config.contains("sni_hostname: \"www.example.com\""));
        assert!(shoes_config.contains("type: shadowsocks"));
        assert!(shoes_config.contains("password: \"ss-secret\""));
    }

    #[test]
    fn builds_v2ray_plugin_websocket_wrapper() {
        let config = r#"
proxies:
  - name: SS WS
    type: ss
    server: ss.example.com
    port: 443
    cipher: aes-128-gcm
    password: ss-secret
    plugin: v2ray-plugin
    plugin-opts:
      mode: websocket
      host: cdn.example.com
      path: /ws
      tls: true
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - SS WS
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("type: tls"));
        assert!(shoes_config.contains("type: ws"));
        assert!(shoes_config.contains("matching_path: \"/ws\""));
        assert!(shoes_config.contains("Host: \"cdn.example.com\""));
        assert!(shoes_config.contains("type: shadowsocks"));
    }

    #[test]
    fn rejects_unsupported_shadowsocks_obfs_plugin_explicitly() {
        let config = r#"
proxies:
  - { name: SS Obfs, type: ss, server: ss.example.com, port: 443, cipher: aes-128-gcm, password: ss-secret, plugin: obfs, plugin-opts.mode: http, plugin-opts.host: www.example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - SS Obfs
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let error = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap_err();
        assert!(error.contains("plugin obfs is not supported"));
    }

    #[test]
    fn status_json_includes_selected_proxy_and_adapter_error() {
        let home = CString::new("/tmp/clashhm-test").unwrap();
        assert_eq!(clashhm_native_core_init(home.as_ptr()), 0);

        let config = CString::new(
            r#"
proxies:
  - { name: SS Obfs, type: ss, server: ss.example.com, port: 443, cipher: aes-128-gcm, password: ss-secret, plugin: obfs, plugin-opts.mode: http, plugin-opts.host: www.example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - SS Obfs
rules:
  - MATCH,Proxy
"#,
        )
        .unwrap();
        assert_eq!(clashhm_native_core_start_tun(28, config.as_ptr()), -102);
        let status_ptr = clashhm_native_core_get_status_json();
        let status = unsafe { CStr::from_ptr(status_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        clashhm_native_core_free_string(status_ptr);
        assert!(status.contains("\"selectedGroup\":\"Proxy\""), "{status}");
        assert!(status.contains("\"selectedProxy\":\"SS Obfs\""), "{status}");
        assert!(status.contains("plugin obfs is not supported"), "{status}");
    }

    #[test]
    fn status_json_reports_skipped_rule_types() {
        let home = CString::new("/tmp/clashhm-test").unwrap();
        assert_eq!(clashhm_native_core_init(home.as_ptr()), 0);

        let config = CString::new(
            r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - A
rules:
  - DOMAIN-KEYWORD,google,Proxy
  - GEOIP,PRIVATE,DIRECT
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  - GEOSITE,definitely-missing-category,DIRECT
  - MATCH,Proxy
"#,
        )
        .unwrap();
        let _ = clashhm_native_core_start_tun(28, config.as_ptr());
        let status_ptr = clashhm_native_core_get_status_json();
        let status = unsafe { CStr::from_ptr(status_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        clashhm_native_core_free_string(status_ptr);
        assert!(status.contains("\"skippedRuleCount\":1"), "{status}");
        assert!(!status.contains("DOMAIN-KEYWORD"), "{status}");
        assert!(status.contains("GEOSITE"), "{status}");
        assert!(!status.contains("GEOIP"), "{status}");
    }

    #[test]
    fn parses_quoted_flow_style_clash_keys() {
        let config = r#"
proxies:
  - {"name": "SS Quoted", "type": "ss", "server": "ss.example.com", "port": 443, "cipher": "aes-128-gcm", "password": "secret"}
proxy-groups:
  - {"name": "🚀 节点选择", "type": "select", "proxies": ["SS Quoted"]}
rules:
  - MATCH,🚀 节点选择
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        assert_eq!(proxies.len(), 1);
        assert_eq!(groups.len(), 1);
        assert_eq!(rules.len(), 1);
        assert_eq!(proxies[0].name, "SS Quoted");
        assert_eq!(groups[0].all, vec!["SS Quoted".to_string()]);
        assert!(build_shoes_tun_config(28, &groups, &proxies, &rules).is_ok());
    }

    #[test]
    fn parses_inline_flow_array_sections() {
        let config = r#"
proxies: [{"name": "SS Inline", "type": "ss", "server": "ss.example.com", "port": 443, "cipher": "aes-128-gcm", "password": "secret"}]
proxy-groups: [{"name": "🚀 节点选择", "type": "select", "proxies": ["SS Inline"]}]
rules:
  - MATCH,🚀 节点选择
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        assert_eq!(proxies.len(), 1);
        assert_eq!(groups.len(), 1);
        assert_eq!(rules.len(), 1);
        assert_eq!(proxies[0].name, "SS Inline");
        assert_eq!(groups[0].all, vec!["SS Inline".to_string()]);
        assert!(build_shoes_tun_config(28, &groups, &proxies, &rules).is_ok());
    }

    #[test]
    fn parses_dash_then_nested_fields_style() {
        let config = r#"
proxies:
  -
    name: 'Trojan Nested'
    type: trojan
    server: trojan-nested.example.com
    port: 4005
    password: secret
    sni: front.example.com
proxy-groups:
  -
    name: '🚀 节点选择'
    type: select
    proxies:
      - 'Trojan Nested'
rules:
  - MATCH,🚀 节点选择
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        assert_eq!(proxies.len(), 1);
        assert_eq!(groups.len(), 1);
        assert_eq!(rules.len(), 1);
        assert_eq!(proxies[0].name, "Trojan Nested");
        assert_eq!(groups[0].all, vec!["Trojan Nested".to_string()]);
    }

    #[test]
    fn skips_clash_rules_that_embedded_adapter_cannot_model() {
        let config = r#"
proxies:
  - name: SS
    type: ss
    server: ss.example.com
    port: 443
    cipher: aes-128-gcm
    password: secret
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - SS
rules:
  - DOMAIN-KEYWORD,google,Proxy
  - GEOIP,PRIVATE,DIRECT
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        assert_eq!(rules.len(), 5);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(shoes_config.contains("0.0.0.0/0"));
        assert!(shoes_config.contains("domain_keywords: \"google\""));
        assert!(shoes_config.contains("masks: \"10.0.0.0/8\""));
        assert!(shoes_config.contains("masks:"));
        assert!(shoes_config.contains("geoip_countries: \"CN\""));
        assert!(!shoes_config.contains("masks: \"CN\""));
    }

    #[test]
    fn filters_subscription_metadata_proxy_nodes() {
        let config = r#"
proxies:
  -
    name: '🇭🇰 套餐到期日期：2027-04-23'
    type: trojan
    server: metadata.example.com
    port: 4005
    password: secret
    sni: front.example.com
  -
    name: 'HK Real'
    type: trojan
    server: hk.example.com
    port: 443
    password: secret
    sni: hk.example.com
proxy-groups:
  -
    name: '🚀 节点选择'
    type: select
    proxies:
      - '🇭🇰 套餐到期日期：2027-04-23'
      - 'HK Real'
rules:
  - MATCH,🚀 节点选择
"#;
        let (proxies, groups, _rules) = parse_clash_config(config);
        assert_eq!(proxies.len(), 1);
        assert_eq!(proxies[0].name, "HK Real");
        assert_eq!(groups[0].all, vec!["HK Real".to_string()]);
        assert_eq!(groups[0].now, "HK Real");
    }

    #[cfg(feature = "shoes-backend")]
    #[test]
    fn generated_wrapped_config_is_parseable_by_shoes() {
        let config = r#"
proxies:
  - { name: VMess WS, type: vmess, server: example.com, port: 443, uuid: b0e80a62-8a51-47f0-91f1-f0f7faf8d9d4, cipher: auto, tls: true, network: ws, path: /ws, servername: example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - VMess WS
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(
            shoes::config::load_config_str(&shoes_config).is_ok(),
            "{shoes_config}"
        );
    }

    #[cfg(feature = "shoes-backend")]
    #[test]
    fn generated_h2_transport_config_is_parseable_by_shoes() {
        let configs = [
            r#"
proxies:
  - { name: VMess H2, type: vmess, server: h2.example.com, port: 443, uuid: b0e80a62-8a51-47f0-91f1-f0f7faf8d9d4, cipher: auto, tls: true, network: h2, h2-opts: { path: /vmess, host: cdn.example.com } }
proxy-groups:
  - { name: Proxy, type: select, proxies: [VMess H2] }
"#,
            r#"
proxies:
  - { name: VLESS H2, type: vless, server: h2.example.com, port: 443, uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0, tls: true, network: h2, h2-opts: { path: /vless, host: cdn.example.com } }
proxy-groups:
  - { name: Proxy, type: select, proxies: [VLESS H2] }
"#,
            r#"
proxies:
  - { name: Trojan H2, type: trojan, server: h2.example.com, port: 443, password: secret, tls: true, network: h2, h2-opts: { path: /trojan, host: cdn.example.com } }
proxy-groups:
  - { name: Proxy, type: select, proxies: [Trojan H2] }
"#,
        ];
        for config in configs {
            let (proxies, groups, rules) = parse_clash_config(config);
            let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
            assert!(
                shoes::config::load_config_str(&shoes_config).is_ok(),
                "{shoes_config}"
            );
            assert!(shoes_config.contains("type: h2"), "{shoes_config}");
            assert!(!shoes_config.contains("h2mux:"), "{shoes_config}");
        }
    }

    #[cfg(feature = "shoes-backend")]
    #[test]
    fn generated_grpc_transport_config_is_parseable_by_shoes() {
        let configs = [
            r#"
proxies:
  - { name: VMess GRPC, type: vmess, server: grpc.example.com, port: 443, uuid: b0e80a62-8a51-47f0-91f1-f0f7faf8d9d4, cipher: auto, tls: true, network: grpc, grpc-opts: { serviceName: vmess } }
proxy-groups:
  - { name: Proxy, type: select, proxies: [VMess GRPC] }
"#,
            r#"
proxies:
  - { name: VLESS GRPC, type: vless, server: grpc.example.com, port: 443, uuid: b85798ef-e9dc-46a4-9a87-8da4499d36d0, tls: true, network: grpc, grpc-opts: { serviceName: vless } }
proxy-groups:
  - { name: Proxy, type: select, proxies: [VLESS GRPC] }
"#,
            r#"
proxies:
  - { name: Trojan GRPC, type: trojan, server: grpc.example.com, port: 443, password: secret, tls: true, network: grpc, grpc-opts: { serviceName: trojan } }
proxy-groups:
  - { name: Proxy, type: select, proxies: [Trojan GRPC] }
"#,
        ];
        for config in configs {
            let (proxies, groups, rules) = parse_clash_config(config);
            let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
            assert!(
                shoes::config::load_config_str(&shoes_config).is_ok(),
                "{shoes_config}"
            );
            assert!(shoes_config.contains("type: grpc"), "{shoes_config}");
            assert!(
                shoes_config.contains("alpn_protocols: \"h2\""),
                "{shoes_config}"
            );
        }
    }

    #[cfg(feature = "shoes-backend")]
    #[test]
    fn generated_rule_config_is_parseable_by_shoes() {
        let config = r#"
proxies:
  - { name: A, type: ss, server: proxy.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - A
rules:
  - DOMAIN-KEYWORD,google,Proxy
  - DOMAIN-SUFFIX,example.com,DIRECT
  - GEOIP,PRIVATE,DIRECT
  - GEOSITE,geolocation-cn,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - MATCH,Proxy
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(
            shoes::config::load_config_str(&shoes_config).is_ok(),
            "{shoes_config}"
        );
    }

    #[cfg(feature = "shoes-backend")]
    #[test]
    fn generated_snell_config_is_parseable_by_shoes() {
        let config = r#"
proxies:
  - { name: Snell, type: snell, server: snell.example.com, port: 443, cipher: aes-128-gcm, password: secret }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Snell
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(
            shoes::config::load_config_str(&shoes_config).is_ok(),
            "{shoes_config}"
        );
    }

    #[cfg(feature = "shoes-backend")]
    #[test]
    fn generated_anytls_config_is_parseable_by_shoes() {
        let config = r#"
proxies:
  - { name: AnyTLS, type: anytls, server: anytls.example.com, port: 443, password: secret, sni: anytls.example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - AnyTLS
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(
            shoes::config::load_config_str(&shoes_config).is_ok(),
            "{shoes_config}"
        );
    }

    #[cfg(feature = "shoes-backend")]
    #[test]
    fn generated_naiveproxy_config_is_parseable_by_shoes() {
        let config = r#"
proxies:
  - { name: Naive, type: naiveproxy, server: naive.example.com, port: 443, username: user, password: secret, sni: naive.example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Naive
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(
            shoes::config::load_config_str(&shoes_config).is_ok(),
            "{shoes_config}"
        );
    }

    #[cfg(feature = "shoes-backend")]
    #[test]
    fn generated_shadowtls_plugin_config_is_parseable_by_shoes() {
        let config = r#"
proxies:
  - { name: SS ShadowTLS, type: ss, server: shadow.example.com, port: 443, cipher: aes-128-gcm, password: ss-secret, plugin: shadow-tls, shadow-tls-password: shadow-secret, shadow-tls-sni: www.example.com }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - SS ShadowTLS
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(
            shoes::config::load_config_str(&shoes_config).is_ok(),
            "{shoes_config}"
        );
    }

    #[cfg(feature = "shoes-backend")]
    #[test]
    fn generated_v2ray_plugin_config_is_parseable_by_shoes() {
        let config = r#"
proxies:
  - { name: SS WS, type: ss, server: ss.example.com, port: 443, cipher: aes-128-gcm, password: ss-secret, plugin: v2ray-plugin, plugin-opts.mode: websocket, plugin-opts.host: cdn.example.com, plugin-opts.path: /ws, plugin-opts.tls: true }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - SS WS
"#;
        let (proxies, groups, rules) = parse_clash_config(config);
        let shoes_config = build_shoes_tun_config(28, &groups, &proxies, &rules).unwrap();
        assert!(
            shoes::config::load_config_str(&shoes_config).is_ok(),
            "{shoes_config}"
        );
    }
}
