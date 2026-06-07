# Protocol Backend Roadmap

ClashHM treats a protocol as supported only when the VPN Extension native core can carry real device traffic through it. Parsing a Clash node is not enough.

## Current Decision

Keep the `VpnExtensionAbility` data path. Do not move the core back to the UI process and do not add unrelated background-keepalive capabilities.

The next protocol work should happen in the embedded backend, not in the ArkTS UI layer:

```text
ArkTS config/subscription layer
  -> Clash-compatible normalized config
  -> C++ NAPI bridge
  -> Rust native-core adapter
  -> embedded protocol backend
  -> TUN traffic
```

## Supported Today

The current embedded backend supports the selected-node path for:

- Shadowsocks
- Snell
- AnyTLS
- NaiveProxy
- SOCKS5
- HTTP / HTTPS
- VMess
- VLESS
- Trojan
- TLS / WebSocket / Reality / ShadowTLS wrappers
- Clash/Xray HTTP/2 transport wrapper
- v2ray-plugin WebSocket wrapping
- VMess / VLESS / Trojan `mux` / `h2mux`

## Capability Matrix

| Clash node / transport | Current status | Notes |
| --- | --- | --- |
| `DIRECT` | Supported | Used for direct groups and rules. |
| Shadowsocks / `ss` | Supported | AEAD and supported 2022 ciphers through shoes validation. Unsupported plugins fail explicitly. |
| Snell | Supported | Basic client mapping. |
| SOCKS5 | Supported | Username/password supported. |
| HTTP / HTTPS proxy | Supported | HTTP CONNECT upstream. |
| VMess | Supported | TCP, TLS, WebSocket, Reality/TLS wrappers where applicable. |
| VLESS | Supported | TCP, TLS, WebSocket, Reality and Vision where supported by shoes. |
| Trojan | Supported | TCP/TLS and supported wrappers. |
| AnyTLS | Supported | Client outbound exists in shoes. |
| NaiveProxy | Supported | Uses shoes NaiveProxy HTTP/2 CONNECT implementation. |
| `network: ws` / `ws-opts` | Supported | Maps to shoes WebSocket wrapper. |
| Clash/Xray `network: h2` | Initial support | Uses a real HTTP/2 transport wrapper with `h2-opts.path` and `h2-opts.host`; not mapped to shoes h2mux. Needs more real-device coverage across subscription variants. |
| Clash `mux` / `h2mux` / `smux` options | Partially supported | Maps to shoes sing-box-style h2mux for VMess/VLESS/Trojan. This is not Clash/Xray `network: h2`. |
| Hysteria2 / HY2 | Unsupported | Shoes currently has server-side Hysteria2 code, but no client outbound config/handler. |
| TUIC / TUIC v5 | Unsupported | Shoes currently has server-side TUIC code, but no client outbound config/handler. |
| `network: grpc` | Unsupported | Shoes has no Clash/Xray gRPC client transport wrapper. |

## Remaining Protocols

### Hysteria2

Estimated size: large.

Required backend work:

- HY2 client outbound
- QUIC transport
- TLS and ALPN handling
- password/auth handling
- UDP flow handling
- timeout, reconnect, and cancellation behavior
- TUN integration tests on real HarmonyOS device

Adapter-only work is insufficient because the vendored backend does not currently expose a HY2 client outbound.

### TUIC

Estimated size: large.

Required backend work:

- TUIC v5 client outbound
- QUIC transport
- UUID/password authentication
- congestion control options
- UDP relay behavior
- TUN integration tests on real HarmonyOS device

Adapter-only work is insufficient because the vendored backend does not currently expose a TUIC client outbound.

### gRPC Transport

Estimated size: medium to large.

Required backend work:

- Clash/Xray gRPC transport mapping
- service name
- authority / host behavior
- TLS / SNI behavior
- stream lifecycle and reconnect handling
- tests for VMess/VLESS/Trojan over gRPC

This is not equivalent to plain TCP.

### Clash/Xray `network: h2`

Initial support exists.

Implemented:

- HTTP/2 transport client
- TLS / SNI / host handling
- path and host behavior

Remaining work:

- tests for VMess/VLESS/Trojan over HTTP/2 transport
- broader real-device coverage with real subscription variants
- optional extra header behavior if subscriptions require it

This is not equivalent to shoes/sing-box `h2mux`; it must not be mapped to `h2mux`.

## Rule Backend Work

The embedded backend currently models routing through `NetLocationMask`. This handles:

- `MATCH`
- `DOMAIN`
- `DOMAIN-SUFFIX`
- `DOMAIN-KEYWORD`
- `IP-CIDR`
- `IP-CIDR6`
- `DST-PORT`
- basic `GEOIP,PRIVATE/LAN`
- basic `GEOSITE,cn/geolocation-cn`

The following need backend matcher expansion:

- full MMDB/dat backed `GEOIP`
- full MMDB/dat backed `GEOSITE`
- advanced / unresolved `RULE-SET`

Current behavior is explicit diagnostic fallback: unsupported rules are skipped, and status JSON reports `skippedRuleCount` and `skippedRuleTypes`.

## Recommended Implementation Order

1. Finish rule matcher expansion before new transport protocols.
2. Add local MMDB/dat based full `GEOIP` / `GEOSITE` support.
3. Add gRPC transport for VMess/VLESS/Trojan.
4. Add HY2 and TUIC only after the backend has a real QUIC client path.

Reasoning: rule and DNS correctness affects every existing protocol, while HY2/TUIC only affect subscriptions that use those node types.

## Acceptance Criteria

Each new protocol or matcher must have:

- Clash config parser test
- generated backend config test
- backend parseability test when applicable
- native status diagnostics
- real HarmonyOS device connection test
- node switch test
- disconnect/reconnect test

Do not mark a protocol as supported until real traffic passes through it on device.
