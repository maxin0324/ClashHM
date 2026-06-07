#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="${CLASHHM_ARTIFACT_DIR:-$ROOT_DIR/artifacts}"
NATIVE_CORE_DIR="$ROOT_DIR/clash/src/main/cpp/native-core"
LIB="$NATIVE_CORE_DIR/libclashhm_native_core.a"
HEADER="$NATIVE_CORE_DIR/native_core.h"

if [[ ! -f "$LIB" || ! -f "$HEADER" ]]; then
  cat >&2 <<'EOF'
Missing native-core artifact files.

Expected:
  clash/src/main/cpp/native-core/libclashhm_native_core.a
  clash/src/main/cpp/native-core/native_core.h

Build them first:
  OHOS_NATIVE_HOME=/path/to/openharmony/native native-core/build-ohos.sh
EOF
  exit 2
fi

"$ROOT_DIR/scripts/verify-native-core-artifact.sh" >/dev/null

mkdir -p "$ARTIFACT_DIR"
VERSION="$(grep -m1 '^version = ' "$ROOT_DIR/native-core/Cargo.toml" | sed -E 's/version = "([^"]+)"/\1/')"
GIT_REV="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="clashhm-native-core-ohos-arm64-v${VERSION}-${GIT_REV}-${STAMP}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/$NAME"
cp "$LIB" "$WORK_DIR/$NAME/libclashhm_native_core.a"
cp "$HEADER" "$WORK_DIR/$NAME/native_core.h"
cat > "$WORK_DIR/$NAME/MANIFEST.txt" <<EOF
name=$NAME
native_core_version=$VERSION
git_rev=$GIT_REV
target=aarch64-unknown-linux-ohos
library=libclashhm_native_core.a
header=native_core.h
created_utc=$STAMP
EOF

tar -C "$WORK_DIR" -czf "$ARTIFACT_DIR/$NAME.tar.gz" "$NAME"
sha256sum "$ARTIFACT_DIR/$NAME.tar.gz" > "$ARTIFACT_DIR/$NAME.tar.gz.sha256"

echo "$ARTIFACT_DIR/$NAME.tar.gz"
echo "$ARTIFACT_DIR/$NAME.tar.gz.sha256"
