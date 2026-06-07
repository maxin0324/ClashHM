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
- Hysteria2 / HY2 initial TCP/UDP path
- TUIC / TUIC v5 initial TCP/UDP path
- TLS / WebSocket / Reality / ShadowTLS wrappers
- Clash/Xray HTTP/2 transport wrapper
- Clash/Xray gRPC transport wrapper
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
| Clash/Xray `network: grpc` | Initial support | Uses a real gRPC-over-HTTP/2 transport wrapper with `grpc-opts.serviceName`; not mapped to plain TCP or h2mux. Needs more real-device coverage across subscription variants. |
| Clash `mux` / `h2mux` / `smux` options | Partially supported | Maps to shoes sing-box-style h2mux for VMess/VLESS/Trojan. This is not Clash/Xray `network: h2`. |
| Hysteria2 / HY2 | Initial TCP + UDP support | HY2 client config, `password`/`auth`/`auth-str` credential aliases, HTTP/3 auth, QUIC stream setup, TCP request framing, first-hop UDP datagrams, and UDP fragmentation/reassembly are implemented. HY2 obfs and real-device compatibility coverage are still pending. |
| TUIC / TUIC v5 | Initial TCP + UDP support | TUIC v5 client config, `password`/`token` credential aliases, QUIC auth, TCP CONNECT stream framing, first-hop UDP datagrams, and UDP fragmentation/reassembly are implemented. Non-default congestion option mapping and real-device compatibility coverage are still pending. |

## Remaining Protocol Work

### Hysteria2

Estimated size: medium for validation and option compatibility.

Implemented:

- HY2 TCP client outbound
- `password` / `auth` / `auth-str` credential aliases
- QUIC transport
- TLS and ALPN handling
- password/auth handling
- TCP request stream framing
- First-hop UDP datagram flow handling
- UDP fragmentation/reassembly

Remaining work:

- obfs-related HY2 options when supported by backend dependencies
- timeout, reconnect, and cancellation behavior
- TUN integration tests on real HarmonyOS device

TCP outbound, first-hop UDP datagrams, and datagram fragmentation/reassembly are now wired into the vendored backend. Remaining work is broader Clash option coverage and real-device validation against commercial HY2 subscriptions.

### TUIC

Estimated size: medium for validation and option compatibility.

Implemented:

- TUIC v5 TCP client outbound
- `password` / `token` credential aliases
- QUIC transport
- UUID/password authentication
- TCP CONNECT stream framing
- First-hop UDP datagram relay behavior
- UDP fragmentation/reassembly

Remaining work:

- congestion control option mapping beyond the current QUIC defaults
- Clash option compatibility for more subscription variants
- TUN integration tests on real HarmonyOS device

TCP outbound, first-hop UDP datagrams, and datagram fragmentation/reassembly are now wired into the vendored backend. Remaining work is additional Clash option coverage and real-device validation against commercial TUIC subscriptions.

### gRPC Transport

Initial support exists.

Implemented:

- Clash/Xray gRPC transport mapping
- service name
- authority / host behavior
- TLS / SNI behavior
- parser/generated-config/backend-parseability tests for VMess, VLESS, and Trojan over gRPC

Remaining work:

- broader real-device coverage with real subscription variants

This is not equivalent to plain TCP.

### Clash/Xray `network: h2`

Initial support exists.

Implemented:

- HTTP/2 transport client
- TLS / SNI / host handling
- path and host behavior
- parser/generated-config/backend-parseability tests for VMess, VLESS, and Trojan over HTTP/2 transport

Remaining work:

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
- MMDB-backed `GEOIP,<country-code>`
- built-in private `GEOSITE,cn/private/local/lan`
- dat-backed `GEOSITE,<category>` Domain/Full/Plain entries

The following need backend matcher expansion:

- GEOSITE regex entries that cannot be represented by `NetLocationMask`
- dynamic / unresolved `RULE-SET` forms that cannot be materialized locally yet

Current behavior is explicit diagnostic fallback: unsupported rules are skipped, and status JSON reports `skippedRuleCount` and `skippedRuleTypes`.

## Recommended Implementation Order

1. Validate HY2/TUIC TCP and UDP relay behavior on real HarmonyOS devices because the code path now exists but QUIC behavior depends on real servers.
2. Harden HY2/TUIC option compatibility against more real subscription variants.
3. Finish dynamic `RULE-SET` and remaining matcher gaps that cannot be materialized locally yet.
4. Continue broader h2/gRPC real-device coverage for VMess, VLESS, and Trojan variants.

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
