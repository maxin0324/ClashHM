#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="aarch64-unknown-linux-ohos"
FEATURES="${CLASHHM_NATIVE_CORE_FEATURES:-shoes-backend}"
CARGO_BIN="${CARGO:-cargo}"
RUSTUP_BIN="${RUSTUP:-rustup}"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT_DIR/target}"
CARGO_EXTRA_ARGS="${CLASHHM_CARGO_EXTRA_ARGS:-}"

if [[ -z "${OHOS_NATIVE_HOME:-}" && -n "${OHOS_SYSROOT:-}" ]]; then
  OHOS_NATIVE_HOME="$(cd "$(dirname "$OHOS_SYSROOT")" && pwd)"
fi

if [[ -z "${OHOS_NATIVE_HOME:-}" ]]; then
  cat >&2 <<'EOF'
OHOS_NATIVE_HOME or OHOS_SYSROOT is required.

Example:
  export OHOS_NATIVE_HOME=/data/app/sdk.org/sdk_1.0.0/default/openharmony/native
  native-core/build-ohos.sh
EOF
  exit 2
fi

SYSROOT="${OHOS_SYSROOT:-$OHOS_NATIVE_HOME/sysroot}"
if [[ -n "${OHOS_CLANG:-}" ]]; then
  CLANG="$OHOS_CLANG"
else
  CLANG=""
  for candidate in \
    "$OHOS_NATIVE_HOME/llvm/bin/clang" \
    "$(cd "$OHOS_NATIVE_HOME/.." 2>/dev/null && pwd)/hms/native/BiSheng/bin/clang" \
    "$(cd "$OHOS_NATIVE_HOME/../.." 2>/dev/null && pwd)/hms/native/BiSheng/bin/clang"
  do
    if [[ -x "$candidate" ]]; then
      CLANG="$candidate"
      break
    fi
  done
fi

if [[ -n "${OHOS_AR:-}" ]]; then
  AR="$OHOS_AR"
else
  AR=""
  for candidate in \
    "$OHOS_NATIVE_HOME/llvm/bin/llvm-ar" \
    "$(dirname "${CLANG:-}")/llvm-ar" \
    "$(dirname "${CLANG:-}")/ar"
  do
    if [[ -x "$candidate" ]]; then
      AR="$candidate"
      break
    fi
  done
fi

if [[ -z "$CLANG" || ! -x "$CLANG" ]]; then
  echo "Cannot find OHOS clang. Set OHOS_CLANG=/path/to/clang." >&2
  exit 2
fi

if [[ -z "$AR" || ! -x "$AR" ]]; then
  echo "Cannot find OHOS ar/llvm-ar. Set OHOS_AR=/path/to/llvm-ar." >&2
  exit 2
fi

if [[ ! -d "$SYSROOT" ]]; then
  echo "Cannot find OHOS sysroot: $SYSROOT. Set OHOS_SYSROOT=/path/to/sysroot." >&2
  exit 2
fi

mkdir -p "$ROOT_DIR/.cargo"
cat > "$ROOT_DIR/.cargo/config.toml" <<EOF
[target.$TARGET]
linker = "$CLANG"
ar = "$AR"
rustflags = [
  "-C", "link-arg=--target=aarch64-linux-ohos",
  "-C", "link-arg=--sysroot=$SYSROOT"
]
EOF

if command -v "$RUSTUP_BIN" >/dev/null 2>&1; then
  "$RUSTUP_BIN" target add "$TARGET"
else
  echo "rustup not found; assuming Rust target $TARGET is already installed or supported by this toolchain." >&2
fi

cd "$ROOT_DIR"
if [[ "$FEATURES" == "none" ]]; then
  "$CARGO_BIN" build --manifest-path "$ROOT_DIR/Cargo.toml" --target "$TARGET" --release --no-default-features $CARGO_EXTRA_ARGS
else
  "$CARGO_BIN" build --manifest-path "$ROOT_DIR/Cargo.toml" --target "$TARGET" --release --features "$FEATURES" $CARGO_EXTRA_ARGS
fi

OUT_DIR="$ROOT_DIR/../clash/src/main/cpp/native-core"
mkdir -p "$OUT_DIR"
cp "$TARGET_DIR/$TARGET/release/libclashhm_native_core.a" "$OUT_DIR/libclashhm_native_core.a"
if [[ "${CLASHHM_SKIP_ARCHIVE_STRIP:-0}" != "1" ]] && command -v strip >/dev/null 2>&1; then
  strip \
    --strip-unneeded \
    --remove-section=.comment \
    --remove-section=.note \
    --remove-section=.note.* \
    --remove-section=.llvm_addrsig \
    --remove-section=.eh_frame \
    --remove-section=.eh_frame_hdr \
    "$OUT_DIR/libclashhm_native_core.a" || true
fi
cp "$ROOT_DIR/src/native_core.h" "$OUT_DIR/native_core.h"
echo "native core static library copied to $OUT_DIR"
