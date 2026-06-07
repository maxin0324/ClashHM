# Extension Native Core Design

This document defines the native-core architecture that removes the UI-process core dependency.

## Problem

The old MVP ran mihomo in the UI process and only `hev-socks5-tunnel` inside `VpnExtensionAbility`.

That is usable, but it is not robust:

- VPN traffic depends on the UI process staying alive.
- If HarmonyOS kills or suspends the UI process, the VPN Extension can still exist while its upstream proxy core is gone.
- Workarounds such as fake location/background tasks do not match the app's actual purpose and are not a reliable data-plane design.

## Target

The VPN Extension must own the whole data plane:

```text
ArkUI process
  - subscription management
  - proxy group display
  - latency commands
  - selection commands
  - status/traffic display
        |
        | CommonEvent / file-backed command channel
        v
VpnExtensionAbility process
  - owns VpnConnection and TUN fd
  - starts native proxy core
  - applies node selection
  - exposes proxy groups, latency, traffic, and logs
  - routes TUN traffic directly through the native core
```

The UI process may be killed without destroying the active VPN data path.

## Implementation Choice

Do not hand-write a full Clash/mihomo-compatible core from scratch. A complete core includes:

- TCP and UDP proxy forwarding
- DNS handling, including fake-ip/redir-host behavior
- rule routing
- proxy groups and manual selection
- latency tests
- protocol clients: Shadowsocks, VMess, VLESS, Trojan, Hysteria2, TUIC, SOCKS5, HTTP, and related transports

The viable route is to embed a mature Rust/C++ proxy core and build a Clash-config adapter around it.

Current candidates:

| Candidate | Language | Strength | Gap |
| --- | --- | --- | --- |
| shoes | Rust | Multi-protocol, includes VMess/VLESS/SS/Trojan/Hysteria2/TUIC and TUN mode; host `cargo check --lib --features ffi` passes at `607ccde0c78a851b454c82ac9c76833b60bbeef0` | Needs OHOS FFI/platform patch and Clash YAML adapter |
| shadowsocks-rust | Rust | Mature SS local client | Not enough protocol coverage |
| custom C++ core | C++ | Fits existing CMake/NAPI build | Too much protocol work for full Clash compatibility |

Decision: use `shoes` as the first Rust backend candidate. C++ remains the NAPI/FFI shell. `hev-socks5-tunnel` and UI-process mihomo are no longer retained as runtime fallbacks.

## Native API Boundary

The Extension talks to a single native API. The API must not depend on UI-process mihomo.

```c
int native_core_init(const char* home_dir);
int native_core_start_tun(int tun_fd, const char* clash_config);
int native_core_stop(void);
int native_core_is_running(void);
char* native_core_get_proxies_json(void);
int native_core_select_proxy(const char* group, const char* proxy);
int native_core_test_delay(const char* proxy, const char* url, int timeout_ms);
char* native_core_get_traffic_json(void);
char* native_core_get_connections_json(void);
void native_core_free_string(char* value);
```

The same API is exported through `libclash.so` for ArkTS. The UI service calls these commands through a command channel while the VPN Extension is running.

Current repository state:

- `native-core/` defines the Rust FFI ABI and basic Clash proxy-group parsing.
- With the `shoes-backend` feature enabled, `native-core` converts the selected Clash node into a shoes TUN config and starts `shoes::tun::run_tun_from_config`.
- The adapter supports `direct`, Shadowsocks, Snell, AnyTLS, NaiveProxy, SOCKS5, HTTP, VMess, VLESS, Trojan, TLS/WS/Reality/ShadowTLS/v2ray-plugin WebSocket wrapping, and `mux`/`h2mux` options for VMess/VLESS/Trojan. It handles common Clash block options such as `ws-opts.path`, `ws-opts.headers.Host`, `reality-opts.public-key`, `reality-opts.short-id`, `reality-opts.server-name`, ShadowTLS `plugin-opts`, v2ray-plugin `plugin-opts`, and `udp: false`.
- Flow-style proxy groups such as `proxies: [A, B, DIRECT]` are parsed without truncating at list commas. The ArkTS config parser uses the same nested-aware flow parsing for proxy display and provider expansion. The native parser also expands YAML-native inline `proxy-providers[].proxies` through group `use:` entries and YAML-native inline `rule-providers[].payload` through common `RULE-SET` entries.
- Unsupported protocols or transports return explicit adapter errors. For example, `network: grpc`, Clash/Xray `network: h2`, Hysteria2, and TUIC are not silently treated as plain TCP. Clash/Xray `network: h2` is not shoes/sing-box h2mux.
- Unsupported Shadowsocks plugins such as `obfs`/`simple-obfs` return explicit adapter errors instead of being silently treated as plain Shadowsocks.
- Subscription update materializes remote `proxy-providers` and `rule-providers` to local files when the provider has a `url`. `ConfigManager.generateMergedConfig` expands local provider nodes and expands common `RULE-SET` entries from `domain`, `ipcidr`, and `classical` rule providers before sending config to the Extension.
- The adapter maps common Clash rules to shoes TUN rules: `MATCH`, `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `IP-CIDR`, `IP-CIDR6`, and `DST-PORT`.
- Unsupported routing rules that the embedded shoes rule matcher still cannot model, including `GEOIP`, `GEOSITE`, and unexpanded/advanced `RULE-SET`, are not represented as fake rules. The adapter currently skips them and relies on the Clash `MATCH` rule or generated default rule; status JSON reports `skippedRuleCount` and `skippedRuleTypes` so the UI/logs can explain partial rule coverage. Full parity requires backend rule-matcher work.
- Unsupported client protocols such as Hysteria2 and TUIC fail explicitly because the vendored shoes client config does not expose matching outbound variants; adding real support requires client implementation in the backend, not only adapter YAML changes.
- Proxy selection is applied in the Extension. If the embedded backend is already running, selecting a new proxy rebuilds the selected-node shoes config and restarts the TUN runner. Group selections can resolve to a real proxy, `DIRECT`, `REJECT`/`REJECT-DROP`, or another proxy group.
- The UI process no longer starts the mihomo preview core on app launch, connect, disconnect, proxy refresh, or latency testing. Proxy refresh is config-backed; latency testing is executed through the Extension native-core while connected.
- When Home appears, the UI queries Extension status and marks the connection as active if the Extension native core is still running.
- While connected, UI traffic polling and the log page query the Extension command channel.
- `testDelay` currently performs a native TCP connect probe to the parsed node server/port. Full Clash URL-test semantics are still pending.
- `getStatus` returns structured runtime state: backend engine name, running flag, TUN fd, status text, last adapter/backend error, selected group/proxy, parsed proxy/group/rule counts, uptime, and last latency probe result.
- `getTraffic` and `getConnections` are exposed through the native boundary. They currently return placeholders until shoes traffic accounting and connection tracking are wired.
- `clash_bridge.cpp` exports optional NAPI functions prefixed with `nativeCore`.
- `CMakeLists.txt` requires `clash/src/main/cpp/native-core/libclashhm_native_core.a` and `native_core.h`.
- CMake attempts to build the Rust static library automatically when `bash`, `cargo`, and the OHOS compiler/sysroot are available. `rustup` is optional; when present it installs the OHOS target, otherwise cargo is allowed to build with the current toolchain.
- If the Rust static library is absent and auto-build cannot produce it, DevEco native build fails. This prevents shipping a HAP without the Extension data plane.

This makes the Extension-contained core the only active VPN data plane.

## Config Adapter

The adapter accepts Clash YAML and produces the embedded core's internal config:

1. Parse top-level proxy nodes.
2. Parse proxy groups.
3. Parse rules.
4. Persist selected proxy per group.
5. Generate native-core routing config.
6. Start core with the TUN fd owned by `VpnExtensionAbility`.

The adapter must support at least:

- `proxies`
- `proxy-providers` after provider fetching is implemented
- `rule-providers` when `RULE-SET` entries can be expanded from local `domain`, `ipcidr`, or `classical` provider payloads
- `proxy-groups` with `select`, `url-test`, `fallback`
- `rules` with `MATCH`, `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `IP-CIDR`, `GEOIP`

Unsupported entries must be reported explicitly in status, not silently ignored.

## Process Communication

The UI process and VPN Extension do not share memory. Use CommonEvent as the process boundary.

Current implementation:

- Large startup config uses chunked `com.mx.clashhm.CONFIG_CHUNK` events. `configKind=core` carries the merged Clash config for native-core.
- Small commands use `com.mx.clashhm.NATIVE_CORE_COMMAND` parameters.
- Extension executes the command and publishes `com.mx.clashhm.NATIVE_CORE_RESULT`.
- UI filters results by `commandId`.

If future commands need larger payloads than CommonEvent should carry, add file-backed payloads for those commands only. Do not reintroduce UI-process NAPI state as the active VPN data plane.

Commands:

- `start`
- `stop`
- `getProxies`
- `selectProxy`
- `testDelay`
- `getTraffic`
- `getConnections`
- `closeConnection`
- `setMode`

This avoids assuming that NAPI state in the UI process is the same as NAPI state in the Extension process.

## Migration Plan

1. Remove the old `mihomo-ui-core` / tun2socks fallback runtime. Done.
2. Add native API stubs with deterministic status and errors. Done.
3. Add Rust build scaffolding for `aarch64-unknown-linux-ohos`. Done.
4. Add required CMake/NAPI link point for the native core. Done.
5. Add `native-extension-core` service facade in ArkTS. Done.
6. Add the command/result channel between UI and Extension. Done.
7. Start native-core from `VpnExtensionAbility` without tun2socks fallback. Done.
8. Add first `shoes-backend` runtime integration and selected-node Clash adapter. Done.
9. Send merged Clash config to Extension native-core. Done.
10. Apply selection inside the running Extension native core by restarting the selected-node backend. Done.
11. Add common Clash rule conversion for `MATCH`, `DOMAIN`, `DOMAIN-SUFFIX`, `IP-CIDR`, `IP-CIDR6`, and `DST-PORT`. Done.
12. Add native boundary support for connection list commands. Done, with placeholder data.
13. Materialize remote proxy-providers during subscription updates and expand local provider nodes before sending config to the Extension. Done.
13a. Materialize remote rule-providers and expand common RULE-SET entries before sending config to the Extension. Done.
14. Add optional CMake-triggered Rust static library build for DevEco GUI builds. Done.
15. Produce and verify an actual OHOS Rust static library artifact in a DevEco/HarmonyOS SDK environment.
16. Return explicit native-core adapter errors for unsupported high-impact routing rules and protocols instead of silently falling back to default routing. Done.
17. Extend the Clash adapter to Hysteria2, TUIC, gRPC/H2 transports, GEOIP, DOMAIN-KEYWORD, GEOSITE, unexpanded/advanced RULE-SET forms, and full Clash rule parity.
18. Replace the basic TCP latency probe with full Clash URL-test behavior, and wire real traffic/connections from the Extension core.
19. Stop starting mihomo in the UI process by default. Done.
20. Restore UI connection state from Extension status after UI process recreation. Done.
21. Route connected traffic polling and log-page reads through the Extension command channel. Done, with placeholder native counters until shoes accounting is wired.
22. Keep native-core as the only runtime data path; unsupported protocols must fail explicitly rather than falling back.

## Acceptance Criteria

The root-cause fix is complete only when all of these pass:

- Connecting starts VPN and native core inside `VpnExtensionAbility`.
- After returning to home screen or killing the UI ability, existing VPN traffic continues.
- Reopening the app reconnects to Extension state and shows current proxy/traffic.
- Proxy page can show groups before VPN connects by parsing config, and after VPN connects from Extension state.
- Node selection persists and is applied before the VPN starts routing traffic.
- Latency tests work through Extension native-core while VPN is connected; disconnected latency testing needs a separate non-VPN preview design and must not reintroduce UI-process mihomo.
- Failure messages identify unsupported protocol/config rather than timing out.

## Non-Goals

- Fake location or unrelated background capability.
- A partial in-house protocol stack presented as full Clash compatibility.
- Continuing to depend on UI-process mihomo for the active VPN data path.
