# Repository Guidelines

## Project Structure & Module Organization

- `clash/src/main/ets/pages/`: app pages such as Home, Proxy, Subscribe, Settings, and Log.
- `clash/src/main/ets/components/`: reusable ArkUI components.
- `clash/src/main/ets/services/`: subscription, config, diagnostics, and native bridge logic.
- `clash/src/main/ets/vpnability/`: `VpnExtensionAbility` entry point and VPN lifecycle code.
- `clash/src/main/cpp/`: C++ NAPI bridge and native-core integration.
- `clash/src/main/resources/`: icons, strings, profiles, raw assets, and localization.
- `native-core/`: Rust FFI crate, Clash config adapter, tests, and vendored `shoes` backend.
- `docs/` and `store-assets/`: architecture notes, roadmap, release checklist, and store assets.

## Build, Test, and Development Commands

Use DevEco Studio for normal HAP builds and device runs.

```bash
git lfs install
git lfs pull
bash scripts/verify-native-core-artifact.sh
```

Verifies that native-core split parts are real Git LFS assets.

```bash
bash native-core/build-ohos.sh
```

Rebuilds the Rust native core for OpenHarmony when `OHOS_NATIVE_HOME` and Rust are available.

```bash
cargo test --manifest-path native-core/Cargo.toml --features shoes-backend
```

Runs host tests for parser, routing, status, latency, and traffic behavior.

## Coding Style & Naming Conventions

ArkTS should use explicit types; avoid `any`, `unknown`, and untyped object literals. Prefer declared interfaces/classes for structured data.

Rust follows `rustfmt`, snake_case functions/modules, and explicit errors for unsupported Clash features. Keep FFI-facing APIs stable and documented in `native-core/src/native_core.h`.

Resource names should be descriptive. Keep user-facing strings in resource files.

## Testing Guidelines

Native-core changes should include or update Rust tests under `native-core/src` or the vendored backend. Run `cargo test` before handing off protocol, routing, DNS, or traffic changes.

ArkTS UI and integration changes should be verified in DevEco on a real HarmonyOS device. Test both debug and release builds when touching startup, subscriptions, VPN IPC, or resources.

## Commit & Pull Request Guidelines

Recent history uses short imperative messages, for example `Fix log item overflow`. Keep commits focused and avoid bundling unrelated UI, native-core, and docs changes.

Pull requests should include:

- A concise description of behavior changes.
- Test evidence, such as Rust output or DevEco debug/release validation.
- Screenshots for visible UI changes.
- Notes for native artifact, Git LFS, protocol, VPN lifecycle, or store changes.

## Security & Configuration Tips

Do not commit subscription URLs, private nodes, tokens, signing keys, or local DevEco paths. Treat generated HAP files and native archives as release artifacts unless explicitly intended for Git LFS or GitHub Releases.
