# ClashHM

ClashHM is a Clash-style proxy client for HarmonyOS NEXT. It is built as a native HarmonyOS app and runs its VPN data path inside `VpnExtensionAbility`, so the proxy core stays with the system VPN extension instead of depending on a foreground UI process.

The project is currently focused on making a reliable HarmonyOS NEXT client with subscription management, proxy selection, rule-based routing, traffic stats, and an embedded native core.

## Highlights

- Native HarmonyOS NEXT UI built with ArkTS and ArkUI
- System VPN integration through `VpnExtensionAbility`
- Embedded Rust/C++ native core in the VPN Extension
- Clash subscription import and update
- Proxy groups, node selection, and saved selections
- Rule / Global / Direct modes
- Traffic counters and connection status
- Chinese and English UI
- Light and dark themes
- No UI-process mihomo fallback path

## Current Status

ClashHM is usable on real HarmonyOS NEXT devices for supported protocols. The current architecture is intentionally strict: if a protocol, transport, rule type, or plugin cannot be handled correctly by the embedded core, the app reports an explicit error instead of silently routing traffic incorrectly.

Supported node types and options:

- `direct`
- Shadowsocks
- Snell
- AnyTLS
- NaiveProxy
- SOCKS5
- HTTP / HTTPS
- VMess
- VLESS
- Trojan
- TLS
- WebSocket
- Reality
- ShadowTLS
- v2ray-plugin WebSocket wrapping
- `mux` / `h2mux` options for VMess, VLESS, and Trojan
- `udp: false` on supported nodes

Supported rule handling currently covers common Clash rules such as:

- `MATCH`
- `DOMAIN`
- `DOMAIN-SUFFIX`
- `DOMAIN-KEYWORD`
- `IP-CIDR`
- `IP-CIDR6`
- `DST-PORT`
- Expanded local `RULE-SET` entries for common provider formats
- Basic built-in `GEOIP,PRIVATE/LAN` and `GEOSITE,cn/geolocation-cn` rules
- `url-test` / `fallback` group selection based on native-core latency results

Still unsupported or incomplete:

- Hysteria2
- TUIC
- gRPC transport
- Clash/Xray `network: h2` transport
- Full MMDB/dat backed `GEOIP` / `GEOSITE` routing
- simple-obfs / obfs Shadowsocks plugins
- Full Clash-compatible URL-test behavior

## Why Extension Native Core

Many desktop or Android Clash clients can run a separate long-lived core process. HarmonyOS NEXT has a different lifecycle model, and UI-process based cores are fragile for VPN use.

ClashHM puts the VPN data path into `VpnExtensionAbility`:

```text
ArkUI app process
  - subscription management
  - proxy selection
  - status display
  - settings and logs
          |
          | CommonEvent command channel
          v
VpnExtensionAbility process
  - system VPN TUN fd
  - embedded native core
  - DNS and rule routing
  - selected proxy protocol client
```

This avoids keeping the app alive with unrelated background capabilities and keeps the network path attached to the system VPN extension.

More details are available in [docs/extension-native-core.md](docs/extension-native-core.md).

## Screens and Workflow

1. Add a Clash subscription from the Subscribe page.
2. Open the Proxy page and select a node before connecting.
3. Tap the connect button on the Home page.
4. Allow the HarmonyOS VPN permission prompt.
5. Switch nodes from the Proxy page when needed.
6. Check logs and traffic stats from the app.

Proxy lists are parsed from the local subscription config, so they should be visible even before the VPN is connected. Latency checks and live Extension status require the native core path to be available.

## Build

### Requirements

- DevEco Studio 5.0 or newer
- HarmonyOS NEXT SDK
- HarmonyOS Native SDK
- ARM64 HarmonyOS NEXT device

The repository includes the generated native-core static library used by DevEco builds:

```text
clash/src/main/cpp/native-core/libclashhm_native_core.a
clash/src/main/cpp/native-core/native_core.h
```

This lets DevEco build the HAP without requiring Rust/Cargo on the DevEco machine. If you want to rebuild the native core yourself, install Rust and run:

```bash
export OHOS_NATIVE_HOME=/path/to/openharmony/native
bash native-core/build-ohos.sh
```

Then build the app in DevEco Studio:

1. Open the repository root in DevEco Studio.
2. Sync project dependencies.
3. Build HAP.
4. Install and run on a real device.

Native-core release artifacts can be packaged or installed with:

```bash
bash scripts/package-native-core-artifact.sh
bash scripts/install-native-core-artifact.sh /path/to/clashhm-native-core-ohos-arm64-*.tar.gz
```

## Project Layout

```text
ClashHM/
├── AppScope/                       # App-level HarmonyOS config
├── clash/src/main/
│   ├── ets/                        # ArkTS app, pages, services, VPN ability
│   ├── cpp/                        # NAPI bridge and native build config
│   └── resources/                  # strings, colors, icons, raw resources
├── native-core/                    # Rust native core and Clash adapter
└── docs/                           # Architecture and implementation notes
```

Important modules:

- `clash/src/main/ets/pages` - Home, Proxy, Subscribe, Settings, and Log pages
- `clash/src/main/ets/services` - subscription, config, native-core, and selection services
- `clash/src/main/ets/vpnability` - `VpnExtensionAbility` entry point
- `clash/src/main/cpp` - C++ NAPI bridge
- `native-core` - Rust FFI, Clash config adapter, and embedded backend integration

## Protocol Roadmap

The remaining protocol work is not just a parser task. ClashHM already parses many Clash subscription shapes, but a protocol is only considered supported when the Extension native core can actually route traffic through it.

Estimated work:

- Hysteria2: large. Requires a real HY2 client implementation in the embedded backend or a backend replacement that exposes one. Adapter-only changes are not enough.
- TUIC: large. Same reason as Hysteria2: the current backend does not expose a TUIC client outbound.
- gRPC transport: medium to large. Requires mapping Clash/Xray gRPC transport semantics into a backend transport that actually supports gRPC, plus tests for TLS, SNI, service name, authority, and fallback behavior.
- Clash/Xray `network: h2`: medium to large. This is HTTP/2 transport, not the same thing as h2mux. Supporting it requires an actual HTTP/2 transport path rather than reusing mux settings.

Practical options:

- Extend or replace the embedded backend with mature client implementations for HY2/TUIC/gRPC/H2.
- Keep the current strict adapter and add protocol support one backend capability at a time.
- Avoid claiming compatibility for unsupported protocols until real traffic tests pass on device.

Detailed backend planning is tracked in [docs/protocol-backend-roadmap.md](docs/protocol-backend-roadmap.md).

## Development Notes

ClashHM favors explicit failures over silent fallback. This is especially important for VPN software: a connection that appears successful but routes incorrectly is worse than a clear unsupported-protocol error.

Useful checks:

```bash
cargo test --manifest-path native-core/Cargo.toml --features shoes-backend
```

For HarmonyOS device validation, build and run from DevEco Studio, then test:

- subscription import
- proxy list display before connecting
- node selection persistence
- VPN connection
- Google or other target access
- node switching
- traffic counters
- disconnect and reconnect

The full release checklist is in [docs/release-checklist.md](docs/release-checklist.md).

## References

- [mihomo](https://github.com/MetaCubeX/mihomo)
- [Clash](https://github.com/Dreamacro/clash)
- [sing-box](https://github.com/SagerNet/sing-box)
- [Hiddify](https://github.com/hiddify/hiddify-app)

## License

MIT
