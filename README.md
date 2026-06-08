# ClashHM

A Clash-compatible proxy client for **HarmonyOS NEXT**, with an embedded Rust native core running inside the system VPN Extension.

Unlike desktop Clash wrappers, ClashHM runs the entire VPN data path in `VpnExtensionAbility` — no foreground process required to keep the tunnel alive.

## Features

- **Native HarmonyOS UI** — ArkTS / ArkUI, light & dark themes, Chinese & English
- **System VPN integration** — traffic handled by `VpnExtensionAbility`, not the app process
- **Embedded native core** — Rust proxy engine compiled as a static library, no external binaries
- **Clash subscription import** — YAML configs and `ss://` `vmess://` `vless://` `trojan://` `hysteria2://` share links
- **Proxy management** — groups, node selection, Rule / Global / Direct modes
- **Latency testing** — proxy-chain probe works both before and after VPN connects
- **Traffic monitoring** — real-time upload/download counters and active connections

## Supported Protocols

| Category | Protocols |
|----------|-----------|
| **Proxy** | Shadowsocks, VMess, VLESS, Trojan, Hysteria2, TUIC v5, Snell, AnyTLS, NaiveProxy, SOCKS5, HTTP/S, Direct |
| **Transport** | TLS, WebSocket, HTTP/2, gRPC, Reality, ShadowTLS, v2ray-plugin WS |
| **Multiplex** | `mux` / `h2mux` for VMess, VLESS, Trojan |
| **Rules** | DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, IP-CIDR/6, DST-PORT, GEOIP (MMDB), GEOSITE (dat), RULE-SET, MATCH |

<details>
<summary>Known limitations</summary>

- HY2 obfs and non-default TUIC congestion options not yet implemented
- Remote-only `RULE-SET` providers that cannot be materialized locally
- Regex-only GEOSITE entries
- simple-obfs / obfs Shadowsocks plugins

</details>

## Architecture

```
┌─────────────────────────────┐
│  ArkUI App Process          │
│  ┌────────────────────────┐ │
│  │ Subscription管理       │ │
│  │ Proxy选择 & 延迟测试    │ │
│  │ 流量统计 & 日志         │ │
│  └──────────┬─────────────┘ │
└─────────────┼───────────────┘
              │ CommonEvent IPC
┌─────────────▼───────────────┐
│  VpnExtensionAbility        │
│  ┌────────────────────────┐ │
│  │ System TUN fd          │ │
│  │ Embedded native core   │ │
│  │ DNS → TCP-over-proxy   │ │
│  │ Rule routing engine    │ │
│  └────────────────────────┘ │
└─────────────────────────────┘
```

See [docs/extension-native-core.md](docs/extension-native-core.md) for details.

## Quick Start

1. **Add subscription** — paste a Clash YAML URL or share links on the Subscribe page
2. **Select a node** — pick a proxy from the Proxy page
3. **Connect** — tap the connect button on Home, approve the VPN permission
4. **Done** — switch nodes, check latency, view traffic stats anytime

## Build

### Prerequisites

| Tool | Version |
|------|---------|
| DevEco Studio | 5.0+ |
| HarmonyOS NEXT SDK | latest |
| Target device | ARM64 HarmonyOS NEXT |
| Rust *(optional)* | stable, with `aarch64-unknown-linux-ohos` target |

### Build with prebuilt native core

The repo includes split `.a` parts under `clash/src/main/cpp/native-core/`. CMake reassembles them automatically — no Rust toolchain needed.

```bash
# Just open in DevEco Studio → Sync → Build HAP → Run on device
```

### Rebuild native core from source

```bash
export OHOS_NATIVE_HOME=/path/to/openharmony/native
bash native-core/build-ohos.sh
```

### Run tests

```bash
cargo test --manifest-path native-core/Cargo.toml --features shoes-backend
```

## Project Layout

```
ClashHM/
├── clash/src/main/
│   ├── ets/pages/          # Home, Proxy, Subscribe, Settings, Log
│   ├── ets/services/       # Subscription, config, native-core bridge
│   ├── ets/vpnability/     # VpnExtensionAbility entry point
│   ├── cpp/                # C++ NAPI bridge
│   └── resources/          # i18n strings, icons, raw assets
├── native-core/            # Rust FFI + Clash config adapter
│   └── vendor/shoes/       # Embedded proxy engine
└── docs/                   # Architecture notes & roadmap
```

## Roadmap

Priority order: routing reliability > protocol coverage > polish.

1. Improve rule-provider compatibility and matcher coverage
2. Expand subscription format support (mihomo / sing-box references)
3. Broaden HY2 / TUIC / gRPC / H2 real-device validation
4. Release packaging and user-facing diagnostics

See [docs/protocol-backend-roadmap.md](docs/protocol-backend-roadmap.md) for the full protocol matrix.

## References

- [mihomo](https://github.com/MetaCubeX/mihomo) · [Clash](https://github.com/Dreamacro/clash) · [sing-box](https://github.com/SagerNet/sing-box) · [Hiddify](https://github.com/hiddify/hiddify-app)

## License

MIT
