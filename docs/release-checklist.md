# Release Checklist

This checklist is for producing a GitHub-facing ClashHM build that is safe to test publicly.

## Build Inputs

- DevEco Studio 5.0 or newer
- HarmonyOS NEXT SDK
- HarmonyOS Native SDK
- ARM64 test device
- Tracked native-core artifacts:
  - `clash/src/main/cpp/native-core/libclashhm_native_core.a`
  - `clash/src/main/cpp/native-core/native_core.h`

The tracked static library lets DevEco build without Rust/Cargo on the developer machine. If the Rust native core changes, rebuild it before committing:

```bash
cd native-core
OHOS_NATIVE_HOME=/path/to/openharmony/native ./build-ohos.sh
```

For GitHub releases, also produce a standalone native-core artifact:

```bash
bash scripts/package-native-core-artifact.sh
```

The generated archive contains:

- `libclashhm_native_core.a`
- `native_core.h`
- `MANIFEST.txt`
- a sibling `.sha256` checksum file

The artifact can be restored into a checkout with:

```bash
bash scripts/install-native-core-artifact.sh /path/to/clashhm-native-core-ohos-arm64-*.tar.gz
```

## Pre-Release Validation

Run before tagging a release:

```bash
cargo test --manifest-path native-core/Cargo.toml --features shoes-backend
```

Then validate in DevEco Studio on a real device:

- HAP builds cleanly
- app launches
- subscription can be added and updated
- Proxy page shows nodes while disconnected
- saved node selection appears on Home
- selected node is used after connecting
- VPN permission prompt appears when needed
- VPN connects
- target site access works
- traffic counters move
- node switch works while connected
- disconnect works
- reconnect works without restarting the app
- conflicting existing VPN produces a clear error and recovers after the other VPN is stopped

## Protocol Validation

For every supported node type, test:

- parse from subscription
- display in Proxy page
- select before connection
- connect
- basic HTTP access
- DNS resolution
- switch away and back

Unsupported protocols must produce clear diagnostics instead of silent fallback.

## GitHub Hygiene

- Do not commit HAP outputs or `build/` directories.
- Keep `clash/src/main/cpp/native-core/libclashhm_native_core.a` only while DevEco no-Rust builds need a checked-in artifact.
- Publish `scripts/package-native-core-artifact.sh` output with release builds.
- Move the static library out of Git history and into Git LFS or release artifacts once the native-core ABI stabilizes.
- Keep README focused on app usage and current support status.
- Keep implementation details in `docs/`.

## Tagging

Before creating a release tag:

1. Confirm `git status --short` is clean.
2. Confirm native-core tests pass.
3. Confirm DevEco HAP build passes.
4. Confirm real-device smoke test passes.
5. Update README support status if protocol behavior changed.
