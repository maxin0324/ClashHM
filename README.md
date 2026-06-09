<div align="center">

# 🛡️ ClashHM

**Clash-compatible proxy client for HarmonyOS NEXT**

Embedded Rust native core · System VPN Extension · No foreground process needed

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-HarmonyOS%20NEXT-brightgreen.svg)]()
[![Rust](https://img.shields.io/badge/Core-Rust-orange.svg)]()
[![ArkTS](https://img.shields.io/badge/UI-ArkTS-blue.svg)]()

</div>

---

## ✨ Features

<table>
<tr>
<td width="50%">

🖥️ **Native HarmonyOS UI**
> ArkTS / ArkUI with light & dark themes, Chinese & English

📡 **System VPN Integration**
> Traffic runs in `VpnExtensionAbility`, not the app process

⚙️ **Embedded Native Core**
> Rust proxy engine as static library, zero external binaries

</td>
<td width="50%">

📋 **Subscription Import**
> Clash YAML + `ss://` `vmess://` `vless://` `trojan://` `hy2://` share links

🔀 **Proxy Management**
> Groups, node selection, Rule / Global / Direct modes

📊 **Real-time Monitoring**
> Traffic stats, latency testing, active connections

</td>
</tr>
</table>

---

## 📦 Supported Protocols

| | Supported |
|:--|:--|
| **🔌 Proxy** | Shadowsocks · VMess · VLESS · Trojan · Hysteria2 · TUIC v5 · Snell · AnyTLS · NaiveProxy · SOCKS5 · HTTP/S |
| **🔗 Transport** | TLS · WebSocket · HTTP/2 · gRPC · Reality · ShadowTLS · v2ray-plugin WS |
| **📐 Multiplex** | `mux` / `h2mux` for VMess, VLESS, Trojan |
| **📏 Rules** | DOMAIN · DOMAIN-SUFFIX · DOMAIN-KEYWORD · IP-CIDR/6 · DST-PORT · GEOIP · GEOSITE · RULE-SET · MATCH |

<details>
<summary>⚠️ Known limitations</summary>
<br>

- HY2 obfs and non-default TUIC congestion options not yet implemented
- Remote-only `RULE-SET` providers that cannot be materialized locally
- Regex-only GEOSITE entries
- simple-obfs / obfs Shadowsocks plugins

</details>

---

## 🏗️ Architecture

```
  ┌──────────────────────────────────┐
  │        ArkUI App Process         │
  │                                  │
  │   Subscriptions · Proxy Select   │
  │   Latency Test · Traffic Stats   │
  └───────────────┬──────────────────┘
                  │ CommonEvent IPC
  ┌───────────────▼──────────────────┐
  │      VpnExtensionAbility         │
  │                                  │
  │   TUN fd · Native Core · DNS     │
  │   Rule Engine · Protocol Client  │
  └──────────────────────────────────┘
```

> 📖 See [docs/extension-native-core.md](docs/extension-native-core.md) for details.

---

## 🚀 Quick Start

| Step | Action |
|:----:|--------|
| **1** | **Add subscription** — paste a Clash YAML URL or share links |
| **2** | **Select a node** — pick a proxy from the Proxy page |
| **3** | **Connect** — tap the connect button, approve VPN permission |
| **4** | **Done** — switch nodes, check latency, view stats anytime |

---

## 🔨 Build

### Prerequisites

| Tool | Version |
|:-----|:--------|
| DevEco Studio | 5.0+ |
| HarmonyOS NEXT SDK | latest |
| Target device | ARM64 HarmonyOS NEXT |
| Git LFS | required for prebuilt native-core parts |
| Rust *(optional)* | stable, with `aarch64-unknown-linux-ohos` target |

### With prebuilt native core

The repo includes split `.a` parts under `clash/src/main/cpp/native-core/`.
CMake reassembles them automatically — **no Rust toolchain needed**.
These parts are stored with Git LFS, so run this once after a fresh clone:

```bash
git lfs install
git lfs pull
rm -f clash/src/main/cpp/native-core/libclashhm_native_core.a
bash scripts/verify-native-core-artifact.sh
```

If DevEco reports `unknown directive: version` while linking
`libclashhm_native_core.a`, the clone contains Git LFS pointer files instead of
the real native-core binaries. Run the commands above and rebuild.

```bash
# Open in DevEco Studio → Sync → Build HAP → Run on device
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

---

## 📁 Project Layout

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

---

## 🗺️ Roadmap

> **Priority:** routing reliability → protocol coverage → polish

1. Improve rule-provider compatibility and matcher coverage
2. Expand subscription format support (mihomo / sing-box references)
3. Broaden HY2 / TUIC / gRPC / H2 real-device validation
4. Release packaging and user-facing diagnostics

> 📖 See [docs/protocol-backend-roadmap.md](docs/protocol-backend-roadmap.md) for the full protocol matrix.

---

## 🔗 References

[mihomo](https://github.com/MetaCubeX/mihomo) · [Clash](https://github.com/Dreamacro/clash) · [sing-box](https://github.com/SagerNet/sing-box) · [Hiddify](https://github.com/hiddify/hiddify-app)

## 📄 License

[MIT](LICENSE)
