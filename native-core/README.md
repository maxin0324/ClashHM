# ClashHM Native Core

This crate is the Rust FFI boundary for the Extension-contained proxy core.

The HarmonyOS app no longer keeps a mihomo/tun2socks fallback. DevEco/Hvigor builds must either auto-build this crate or find the generated static library under `clash/src/main/cpp/native-core/`.

Current state:

- Defines the stable native API.
- Parses Clash config with `serde_yaml` first, then falls back to the older line parser. This is closer to mihomo's tolerant YAML handling and supports common block and flow-style subscription output.
- Parses `proxies`, `proxy-groups`, `rules`, provider-expanded local `proxy-providers[].proxies`, YAML-native inline `proxy-providers[].proxies` referenced by group `use:`, and common YAML-native inline `rule-providers[].payload` referenced by `RULE-SET`.
- Parses common Clash `rules` and maps `MATCH`, `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `IP-CIDR`, `IP-CIDR6`, `DST-PORT`, basic `GEOIP,PRIVATE/LAN`, and basic `GEOSITE,cn/geolocation-cn` to shoes TUN rules.
- Expands common `RULE-SET` entries when their provider payload is already local/inline and can be converted into `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `IP-CIDR`, `IP-CIDR6`, or `DST-PORT`.
- Updates `url-test` and `fallback` group selections from cached native-core latency results.
- Skips currently unsupported routing rules such as full MMDB/dat backed `GEOIP` / `GEOSITE` categories and unexpanded/advanced `RULE-SET`, then relies on the Clash `MATCH` rule or generated default rule for fallback routing. Status JSON includes `skippedRuleCount` and `skippedRuleTypes` for diagnostics.
- Receives provider-expanded Clash config from the ArkTS config layer. Remote `proxy-providers` are materialized during subscription update; local provider nodes are expanded before the config is sent to the Extension.
- Returns deterministic status from the embedded backend.
- Vendors the patched `shoes` backend under `native-core/vendor/shoes`, so builds no longer depend on a temporary `/tmp` checkout.
- With `shoes-backend`, converts the selected Clash node into a shoes TUN config and starts the shoes TUN runner. The current adapter supports `direct`, Shadowsocks, Snell, AnyTLS, NaiveProxy, SOCKS5, HTTP/HTTPS, VMess, VLESS, Trojan, TLS/WebSocket/Reality/ShadowTLS wrappers, and `mux`/`h2mux` options for VMess/VLESS/Trojan.
- Parses common nested Clash options for supported transports, including `ws-opts.path`, `ws-opts.headers.Host`, `reality-opts.public-key`, `reality-opts.short-id`, `reality-opts.server-name`, `tls-opts`, and ShadowTLS `plugin-opts`.
- Honors common `udp: false` on supported nodes.
- Fails explicitly for unsupported outbound protocols or transports such as Hysteria2, TUIC, `network: grpc`, and `network: h2`. The vendored shoes client config does not currently expose Hysteria2/TUIC outbound variants, and Clash/Xray `network: h2` is not the same protocol as shoes/sing-box h2mux, so these must not be silently mapped to TCP or h2mux.
- Applies proxy selection inside the Extension. Current running selections are recorded quickly and take effect on the next VPN core start; hot backend reload is still a later task. Group selections can resolve to a real proxy, `DIRECT`, `REJECT`/`REJECT-DROP`, or another proxy group.
- The patched shoes backend converts TUN UDP/53 DNS queries into DNS-over-TCP over the selected proxy chain. This avoids the common Trojan UDP gap where the VPN appears connected but domains cannot resolve.
- Provides a basic TCP connect latency probe for parsed proxy nodes, returns cached latency in proxy-group JSON, and uses those results to update `url-test` / `fallback` group choices. Full Clash-style URL testing through every proxy protocol is still a later adapter task.
- Returns structured runtime status with backend name, selected group/proxy, parsed object counts, uptime, last error, and last latency probe result.
- Exposes traffic and connection APIs through the native boundary. Traffic totals and speeds are now sourced from the patched shoes TUN read/write path.

It is required in the DevEco GUI build. `clash/src/main/cpp/CMakeLists.txt` fails the native build if `libclashhm_native_core.a` and `native_core.h` cannot be produced.

## Backend Dependency

The selected backend is the vendored patched `shoes` crate at `native-core/vendor/shoes`.

Compatibility references:

- mihomo proxy-provider docs: https://wiki.metacubex.one/en/config/proxy-providers/
- mihomo rule-provider docs: https://wiki.metacubex.one/en/config/rule-providers/
- mihomo general config docs: https://wiki.metacubex.one/en/config/general/

The current parser follows the same broad shape by accepting YAML-native objects first and keeping a fallback parser for subscription quirks. Full mihomo parity is still larger than parsing alone: remote provider refresh, rule-provider materialization, GeoSite/GeoIP data, sniffing, and unsupported transport implementations remain separate adapter work.

Local validation completed:

```bash
CARGO_INCREMENTAL=0 CARGO_TARGET_DIR=/home/user/.cache/shoes-target \
  cargo test --manifest-path native-core/Cargo.toml --features shoes-backend
```

The host test suite covers config parsing, unsupported protocol failures, unsupported rule fallback, selection resolution, status output, latency probes, and traffic JSON shape.

## Build for OpenHarmony

DevEco/CMake attempts this build automatically when `bash`, `cargo`, and the OHOS compiler/sysroot are available. If that is not available, run it manually before building the HAP.

```bash
source "$HOME/.cargo/env"
export OHOS_NATIVE_HOME=/data/app/sdk.org/sdk_1.0.0/default/openharmony/native
bash native-core/build-ohos.sh
```

By default the script builds with `--features shoes-backend`, then copies:

- `clash/src/main/cpp/native-core/libclashhm_native_core.a`
- `clash/src/main/cpp/native-core/native_core.h`

If `rustup` is present, the script installs the `aarch64-unknown-linux-ohos` target first; without `rustup`, it directly tries the current Rust toolchain. Missing tools now fail the app build because there is no runtime fallback data path.

To check the optional Rust backend dependency on a host machine:

```bash
CARGO_INCREMENTAL=0 CARGO_TARGET_DIR=/home/user/.cache/clashhm-native-core-target \
  cargo check --manifest-path native-core/Cargo.toml --features shoes-backend
```
