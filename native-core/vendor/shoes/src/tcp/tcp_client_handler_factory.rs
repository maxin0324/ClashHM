//! Factory functions for creating TCP client handlers from config.

use std::io;
use std::sync::Arc;

use log::debug;

use crate::anytls::{AnyTlsClientHandler, PaddingFactory};
use crate::client_proxy_selector::{ClientProxySelector, ConnectAction, ConnectRule};
use crate::config::{
    ClientProxyConfig, GrpcTransportClientConfig, Http2TransportClientConfig, RuleActionConfig,
    RuleConfig, ShadowsocksConfig, TlsClientConfig, WebsocketClientConfig,
};
use crate::h2mux::H2MuxClientHandler;
use crate::http_handler::HttpTcpClientHandler;
use crate::hysteria2_client_handler::Hysteria2TcpClientHandler;
use crate::naiveproxy::{
    GrpcTransportTcpClientHandler, H2TransportTcpClientHandler, NaiveProxyTcpClientHandler,
};
use crate::port_forward_handler::PortForwardClientHandler;
use crate::resolver::Resolver;
use crate::rustls_config_util::create_client_config;
use crate::shadow_tls::ShadowTlsClientHandler;
use crate::shadowsocks::ShadowsocksTcpHandler;
use crate::snell::snell_handler::SnellClientHandler;
use crate::socks_handler::SocksTcpClientHandler;
use crate::tcp::chain_builder::build_client_chain_group;
use crate::tcp::tcp_handler::TcpClientHandler;
use crate::tls_client_handler::TlsClientHandler;
use crate::fingerprint_tls_client_handler::FingerprintTlsClientHandler;
use crate::fingerprint::FingerprintTlsClientConfig;
use crate::trojan_handler::TrojanTcpHandler;
use crate::tuic_client_handler::TuicTcpClientHandler;
use crate::uuid_util::parse_uuid;
use crate::vless::vless_client_handler::VlessTcpClientHandler;
use crate::vmess::VmessTcpClientHandler;
use crate::websocket::WebsocketTcpClientHandler;

fn create_auth_credentials(
    username: Option<String>,
    password: Option<String>,
) -> Option<(String, String)> {
    match (&username, &password) {
        (None, None) => None,
        _ => Some((username.unwrap_or_default(), password.unwrap_or_default())),
    }
}

pub fn create_tcp_client_handler(
    client_proxy_config: ClientProxyConfig,
    default_sni_hostname: Option<String>,
    resolver: Arc<dyn Resolver>,
) -> io::Result<Box<dyn TcpClientHandler>> {
    match client_proxy_config {
        ClientProxyConfig::Direct => {
            panic!("Tried to create a direct tcp client handler");
        }
        ClientProxyConfig::Http {
            username,
            password,
            resolve_hostname,
        } => {
            let http_resolver = if resolve_hostname {
                Some(resolver.clone())
            } else {
                None
            };
            Ok(Box::new(HttpTcpClientHandler::new(
                create_auth_credentials(username, password),
                http_resolver,
            )))
        }
        ClientProxyConfig::Socks { username, password } => Ok(Box::new(SocksTcpClientHandler::new(
            create_auth_credentials(username, password),
        ))),
        ClientProxyConfig::Shadowsocks {
            config,
            udp_enabled,
        } => match config {
            ShadowsocksConfig::Legacy { cipher, password } => Ok(Box::new(
                ShadowsocksTcpHandler::new_client(cipher, &password, udp_enabled),
            )),
            ShadowsocksConfig::Aead2022 { cipher, key_bytes } => Ok(Box::new(
                ShadowsocksTcpHandler::new_aead2022_client(cipher, &key_bytes, udp_enabled),
            )),
        },
        ClientProxyConfig::Snell {
            config: ShadowsocksConfig::Legacy { cipher, password },
            udp_enabled,
        } => Ok(Box::new(SnellClientHandler::new(cipher, &password, udp_enabled))),
        ClientProxyConfig::Snell {
            config: ShadowsocksConfig::Aead2022 { .. },
            ..
        } => {
            panic!(
                "Snell does not support shadowsocks 2022 ciphers (checked during config validation)"
            )
        }
        ClientProxyConfig::Vless {
            user_id,
            udp_enabled,
            h2mux,
        } => {
            let handler: Box<dyn TcpClientHandler> =
                Box::new(VlessTcpClientHandler::new(&user_id, udp_enabled));
            if let Some(h2mux_config) = h2mux {
                Ok(Box::new(H2MuxClientHandler::new(
                    Arc::from(handler),
                    h2mux_config.to_options(),
                )))
            } else {
                Ok(handler)
            }
        }
        ClientProxyConfig::Trojan {
            password,
            shadowsocks,
            h2mux,
        } => {
            let handler: Box<dyn TcpClientHandler> =
                Box::new(TrojanTcpHandler::new_client(&password, &shadowsocks));
            if let Some(h2mux_config) = h2mux {
                Ok(Box::new(H2MuxClientHandler::new(
                    Arc::from(handler),
                    h2mux_config.to_options(),
                )))
            } else {
                Ok(handler)
            }
        }
        ClientProxyConfig::Hysteria2 { .. } => Ok(Box::new(Hysteria2TcpClientHandler::new())),
        ClientProxyConfig::TuicV5 { .. } => Ok(Box::new(TuicTcpClientHandler::new())),
        ClientProxyConfig::Tls(tls_client_config) => {
            let TlsClientConfig {
                verify,
                server_fingerprints,
                sni_hostname,
                alpn_protocols,
                tls_buffer_size,
                protocol,
                key,
                cert,
                vision,
                client_fingerprint,
            } = tls_client_config;

            let sni_hostname = if sni_hostname.is_unspecified() {
                if let Some(ref hostname) = default_sni_hostname {
                    debug!(
                        "Using default sni hostname for TLS client connection: {}",
                        hostname
                    );
                }
                default_sni_hostname
            } else {
                sni_hostname.into_option()
            };

            if let Some(fingerprint) = client_fingerprint {
                let server_name = sni_hostname.unwrap_or_else(|| "example.com".to_string());
                let fp_config = FingerprintTlsClientConfig {
                    fingerprint,
                    server_name,
                    verify,
                    server_fingerprints: server_fingerprints.into_vec(),
                    alpn_protocols: alpn_protocols.into_vec(),
                };

                if vision {
                    let ClientProxyConfig::Vless {
                        user_id,
                        udp_enabled,
                        h2mux: _,
                    } = protocol.as_ref()
                    else {
                        unreachable!();
                    };
                    let user_id_bytes = parse_uuid(user_id)
                        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("Invalid user_id UUID: {e}")))?
                        .into_boxed_slice();
                    Ok(Box::new(FingerprintTlsClientHandler::new_vision_vless(
                        fp_config,
                        user_id_bytes,
                        *udp_enabled,
                    )))
                } else {
                    let handler = create_tcp_client_handler(*protocol, None, resolver.clone())?;
                    Ok(Box::new(FingerprintTlsClientHandler::new(fp_config, handler)))
                }
            } else {
                let key_and_cert_bytes = key.zip(cert).map(|(key, cert)| {
                    let cert_bytes = cert.as_bytes().to_vec();
                    let key_bytes = key.as_bytes().to_vec();
                    (key_bytes, cert_bytes)
                });

                let client_config = Arc::new(create_client_config(
                    verify,
                    server_fingerprints.into_vec(),
                    alpn_protocols.into_vec(),
                    sni_hostname.is_some(),
                    key_and_cert_bytes,
                    false,
                ));

                let server_name = match sni_hostname {
                    Some(s) => rustls::pki_types::ServerName::try_from(s)
                        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("Invalid TLS server name: {e}")))?,
                    None => "example.com".try_into().unwrap(),
                };

                if vision {
                    let ClientProxyConfig::Vless {
                        user_id,
                        udp_enabled,
                        h2mux: _,
                    } = protocol.as_ref()
                    else {
                        unreachable!();
                    };
                    let user_id_bytes = parse_uuid(user_id)
                        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("Invalid user_id UUID: {e}")))?
                        .into_boxed_slice();
                    Ok(Box::new(TlsClientHandler::new_vision_vless(
                        client_config,
                        tls_buffer_size,
                        server_name,
                        user_id_bytes,
                        *udp_enabled,
                    )))
                } else {
                    let handler = create_tcp_client_handler(*protocol, None, resolver.clone())?;

                    Ok(Box::new(TlsClientHandler::new(
                        client_config,
                        tls_buffer_size,
                        server_name,
                        handler,
                    )))
                }
            }
        }
        ClientProxyConfig::Reality {
            public_key,
            short_id,
            sni_hostname,
            cipher_suites,
            vision,
            protocol,
        } => {
            // Decode public key from base64url
            let public_key_bytes =
                crate::reality::decode_public_key(&public_key)
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("Invalid REALITY public key: {e}")))?;

            // Decode short ID from hex string
            let short_id_bytes =
                crate::reality::decode_short_id(&short_id)
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("Invalid REALITY short_id: {e}")))?;

            // Determine SNI hostname
            let sni_hostname = sni_hostname.or(default_sni_hostname.clone());
            let server_name = match sni_hostname {
                Some(s) => rustls::pki_types::ServerName::try_from(s)
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("Invalid REALITY server name: {e}")))?
                    .to_owned(),
                None => {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "REALITY client requires sni_hostname to be specified"));
                }
            };

            let cipher_suites = cipher_suites.into_vec();

            if vision {
                let ClientProxyConfig::Vless {
                    user_id,
                    udp_enabled,
                    h2mux: _, // h2mux not supported with vision
                } = protocol.as_ref()
                else {
                    unreachable!("Vision requires VLESS (should be validated during config load)")
                };
                let user_id_bytes = parse_uuid(user_id)
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("Invalid user_id UUID: {e}")))?
                    .into_boxed_slice();
                Ok(Box::new(
                    crate::reality_client_handler::RealityClientHandler::new_vision_vless(
                        public_key_bytes,
                        short_id_bytes,
                        server_name,
                        cipher_suites,
                        user_id_bytes,
                        *udp_enabled,
                    ),
                ))
            } else {
                let inner_handler = create_tcp_client_handler(*protocol, None, resolver.clone())?;
                Ok(Box::new(crate::reality_client_handler::RealityClientHandler::new(
                    public_key_bytes,
                    short_id_bytes,
                    server_name,
                    cipher_suites,
                    inner_handler,
                )))
            }
        }
        ClientProxyConfig::ShadowTls {
            password,
            sni_hostname,
            protocol,
        } => {
            let sni_hostname = sni_hostname.or(default_sni_hostname);
            let enable_sni = sni_hostname.is_some();

            let server_name = match sni_hostname {
                Some(s) => rustls::pki_types::ServerName::try_from(s)
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("Invalid ShadowTLS server name: {e}")))?,
                None => "example.com".try_into().unwrap(), // Fallback
            };

            // Create TLS config for ShadowTLS - must be TLS 1.3 only.
            // ShadowTLS v3 requires TLS 1.3: we modify the ClientHello session_id to embed
            // an HMAC tag, and rustls doesn't validate session_id echo for TLS 1.3 ServerHello.
            // TLS 1.2 would fail anyway (no supported_versions extension), but restricting
            // here provides defense in depth and fails fast at the TLS level.
            let client_config = Arc::new(create_client_config(
                false,      // No WebPKI verification needed for ShadowTLS
                Vec::new(), // No fingerprints
                Vec::new(), // No ALPN
                enable_sni, // Enable SNI if hostname provided
                None,       // No client cert
                true,       // tls13_only - required for ShadowTLS v3
            ));

            let handler = create_tcp_client_handler(*protocol, None, resolver.clone())?;

            Ok(Box::new(ShadowTlsClientHandler::new(
                password,
                client_config,
                server_name,
                handler,
            )))
        }
        ClientProxyConfig::Vmess {
            cipher,
            user_id,
            udp_enabled,
            h2mux,
        } => {
            let handler: Box<dyn TcpClientHandler> =
                Box::new(VmessTcpClientHandler::new(&cipher, &user_id, udp_enabled));
            if let Some(h2mux_config) = h2mux {
                Ok(Box::new(H2MuxClientHandler::new(
                    Arc::from(handler),
                    h2mux_config.to_options(),
                )))
            } else {
                Ok(handler)
            }
        }
        ClientProxyConfig::Websocket(websocket_client_config) => {
            let WebsocketClientConfig {
                matching_path,
                matching_headers,
                ping_type,
                protocol,
            } = websocket_client_config;

            let handler = create_tcp_client_handler(*protocol, None, resolver.clone())?;

            Ok(Box::new(WebsocketTcpClientHandler::new(
                matching_path,
                matching_headers.map(|h| h.into_iter().collect()),
                ping_type,
                handler,
            )))
        }
        ClientProxyConfig::Http2Transport(http2_transport_config) => {
            let Http2TransportClientConfig {
                path,
                host,
                headers,
                protocol,
            } = http2_transport_config;

            let handler = create_tcp_client_handler(*protocol, None, resolver.clone())?;

            Ok(Box::new(H2TransportTcpClientHandler::new(
                path, host, headers, handler,
            )))
        }
        ClientProxyConfig::GrpcTransport(grpc_transport_config) => {
            let GrpcTransportClientConfig {
                service_name,
                authority,
                headers,
                protocol,
            } = grpc_transport_config;

            let handler = create_tcp_client_handler(*protocol, None, resolver.clone())?;

            Ok(Box::new(GrpcTransportTcpClientHandler::new(
                service_name,
                authority,
                headers,
                handler,
            )))
        }
        ClientProxyConfig::PortForward => Ok(Box::new(PortForwardClientHandler)),
        ClientProxyConfig::Anytls {
            password,
            udp_enabled,
            padding_scheme,
        } => {
            let padding = match padding_scheme {
                Some(lines) => {
                    let scheme = lines.join("\n");
                    Arc::new(
                        PaddingFactory::new(scheme.as_bytes())
                            .expect("Invalid padding scheme in AnyTLS config"),
                    )
                }
                None => PaddingFactory::default_factory(),
            };
            Ok(Box::new(AnyTlsClientHandler::new(password, padding, udp_enabled)))
        }
        ClientProxyConfig::Naiveproxy {
            username,
            password,
            padding,
        } => Ok(Box::new(NaiveProxyTcpClientHandler::new(
            &username, &password, padding,
        ))),
    }
}

pub fn create_tcp_client_proxy_selector(
    rules: Vec<RuleConfig>,
    resolver: Arc<dyn Resolver>,
) -> ClientProxySelector {
    let rules = rules
        .into_iter()
        .map(|rule_config| {
            let RuleConfig {
                masks,
                domain_keywords,
                geoip_countries,
                action,
            } = rule_config;
            let connect_action = match action {
                RuleActionConfig::Allow {
                    override_address,
                    client_chains,
                } => {
                    let chain_group = build_client_chain_group(client_chains, resolver.clone());
                    ConnectAction::new_allow(override_address, chain_group)
                }
                RuleActionConfig::Block => ConnectAction::new_block(),
            };
            ConnectRule::with_domain_keywords(
                masks.into_vec(),
                domain_keywords,
                geoip_countries,
                connect_action,
            )
        })
        .collect::<Vec<_>>();
    ClientProxySelector::new(rules)
}
