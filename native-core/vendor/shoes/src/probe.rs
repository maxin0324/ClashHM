//! Small probe helpers for embedders.

use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::address::NetLocation;
use crate::config::{Config, ConfigSelection};
use crate::resolver::{NativeResolver, Resolver};
use crate::tcp::chain_builder::build_client_proxy_chain;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Connects to `host:port` through the first proxy in `client_group`.
///
/// This intentionally measures only TCP/proxy setup latency. For HTTPS URL-test
/// targets, that covers DNS, proxy protocol handshake and remote TCP reachability
/// without pulling a TLS stack into the mobile FFI boundary.
pub async fn tcp_connect_delay_ms(
    client_group_yaml: &str,
    client_group: &str,
    host: &str,
    port: u16,
    timeout_ms: u64,
) -> std::io::Result<u128> {
    let configs = crate::config::load_config_str(client_group_yaml)?;
    let mut selected = None;
    for config in configs {
        if let Config::ClientConfigGroup(group) = config
            && group.client_group == client_group
        {
            for item in group.client_proxies.into_vec() {
                if let ConfigSelection::Config(client_config) = item {
                    selected = Some(client_config);
                    break;
                }
            }
            break;
        }
    }
    let client_config = selected.ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("client group '{client_group}' did not contain an inline proxy config"),
        )
    })?;

    let resolver: Arc<dyn Resolver> = Arc::new(NativeResolver::new());
    let chain = build_client_proxy_chain(
        crate::option_util::OneOrSome::One(crate::config::ClientChainHop::Single(
            ConfigSelection::Config(client_config),
        )),
        resolver.clone(),
    );
    let target_location = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    };
    let target = NetLocation::from_str(&target_location, None)?;
    let start = Instant::now();
    tokio::time::timeout(
        Duration::from_millis(timeout_ms.max(1)),
        chain.connect_tcp(target.into(), &resolver),
    )
    .await
    .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "probe timed out"))??;
    Ok(start.elapsed().as_millis())
}

/// Performs a Clash-style URL-test request through the selected proxy chain.
///
/// The elapsed time is measured until an HTTP response status line is received.
/// Status codes in the 2xx/3xx range are considered successful; other status
/// codes return an error so callers do not treat a blocked URL as a healthy node.
pub async fn http_url_test_delay_ms(
    client_group_yaml: &str,
    client_group: &str,
    scheme: &str,
    host: &str,
    port: u16,
    path_and_query: &str,
    timeout_ms: u64,
) -> std::io::Result<u128> {
    let timeout = Duration::from_millis(timeout_ms.max(1));
    tokio::time::timeout(timeout, async {
        let (mut stream, start) =
            connect_proxy_chain(client_group_yaml, client_group, host, port).await?;
        let request_path = if path_and_query.is_empty() {
            "/"
        } else {
            path_and_query
        };
        let request = format!(
            "GET {request_path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: ClashHM/1.0\r\nConnection: close\r\n\r\n"
        );

        if scheme.eq_ignore_ascii_case("https") {
            let tls_config =
                crate::rustls_config_util::create_client_config(true, vec![], vec![], true, None, false);
            let connector = tokio_rustls::TlsConnector::from(Arc::new(tls_config));
            let server_name = rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    format!("invalid TLS server name: {host}"),
                )
            })?;
            let mut tls_stream = connector.connect(server_name, stream).await?;
            tls_stream.write_all(request.as_bytes()).await?;
            tls_stream.flush().await?;
            read_success_status_line(&mut tls_stream).await?;
        } else if scheme.eq_ignore_ascii_case("http") {
            stream.write_all(request.as_bytes()).await?;
            stream.flush().await?;
            read_success_status_line(&mut stream).await?;
        } else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("unsupported URL-test scheme: {scheme}"),
            ));
        }

        Ok(start.elapsed().as_millis())
    })
    .await
    .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "URL-test timed out"))?
}

async fn connect_proxy_chain(
    client_group_yaml: &str,
    client_group: &str,
    host: &str,
    port: u16,
) -> std::io::Result<(Box<dyn crate::async_stream::AsyncStream>, Instant)> {
    let configs = crate::config::load_config_str(client_group_yaml)?;
    let mut selected = None;
    for config in configs {
        if let Config::ClientConfigGroup(group) = config
            && group.client_group == client_group
        {
            for item in group.client_proxies.into_vec() {
                if let ConfigSelection::Config(client_config) = item {
                    selected = Some(client_config);
                    break;
                }
            }
            break;
        }
    }
    let client_config = selected.ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("client group '{client_group}' did not contain an inline proxy config"),
        )
    })?;

    let resolver: Arc<dyn Resolver> = Arc::new(NativeResolver::new());
    let chain = build_client_proxy_chain(
        crate::option_util::OneOrSome::One(crate::config::ClientChainHop::Single(
            ConfigSelection::Config(client_config),
        )),
        resolver.clone(),
    );
    let target_location = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    };
    let target = NetLocation::from_str(&target_location, None)?;
    let start = Instant::now();
    let result = chain.connect_tcp(target.into(), &resolver).await?;
    Ok((result.client_stream, start))
}

async fn read_success_status_line<S>(stream: &mut S) -> std::io::Result<()>
where
    S: tokio::io::AsyncRead + Unpin,
{
    let mut buf = [0u8; 1024];
    let mut used = 0usize;
    loop {
        if used == buf.len() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "HTTP response status line too long",
            ));
        }
        let n = stream.read(&mut buf[used..]).await?;
        if n == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "HTTP response ended before status line",
            ));
        }
        used += n;
        if let Some(end) = find_status_line_end(&buf[..used]) {
            let line = std::str::from_utf8(&buf[..end]).map_err(|_| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, "HTTP status line is not UTF-8")
            })?;
            let status = parse_status_code(line)?;
            if (200..400).contains(&status) {
                return Ok(());
            }
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("URL-test HTTP status {status}"),
            ));
        }
    }
}

fn find_status_line_end(buf: &[u8]) -> Option<usize> {
    buf.windows(2).position(|window| window == b"\r\n")
}

fn parse_status_code(line: &str) -> std::io::Result<u16> {
    let mut parts = line.split_ascii_whitespace();
    let version = parts.next().unwrap_or("");
    let status = parts.next().unwrap_or("");
    if !version.starts_with("HTTP/") {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("invalid HTTP status line: {line}"),
        ));
    }
    status.parse::<u16>().map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("invalid HTTP status code: {line}"),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_inline_client_group_for_probe() {
        let yaml = r#"
- client_group: probe
  client_proxies:
    - address: "127.0.0.1:1080"
      protocol:
        type: socks
"#;
        let configs = crate::config::load_config_str(yaml).unwrap();
        let Config::ClientConfigGroup(group) = &configs[0] else {
            panic!("expected client group");
        };
        assert_eq!(group.client_group, "probe");
        assert_eq!(group.client_proxies.iter().count(), 1);
    }

    #[test]
    fn parses_http_status_codes() {
        assert_eq!(parse_status_code("HTTP/1.1 204 No Content").unwrap(), 204);
        assert!(parse_status_code("not http").is_err());
    }
}
