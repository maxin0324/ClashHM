#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -ne 1 ]]; then
  cat >&2 <<'EOF'
Usage:
  scripts/install-native-core-artifact.sh /path/to/clashhm-native-core-ohos-arm64-*.tar.gz

The archive must contain:
  libclashhm_native_core.a
  native_core.h
EOF
  exit 2
fi

ARCHIVE="$1"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Artifact archive not found: $ARCHIVE" >&2
  exit 2
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
tar -C "$WORK_DIR" -xzf "$ARCHIVE"

LIB="$(find "$WORK_DIR" -type f -name libclashhm_native_core.a | head -1)"
HEADER="$(find "$WORK_DIR" -type f -name native_core.h | head -1)"
if [[ -z "$LIB" || -z "$HEADER" ]]; then
  echo "Invalid native-core artifact: missing libclashhm_native_core.a or native_core.h" >&2
  exit 2
fi

OUT_DIR="$ROOT_DIR/clash/src/main/cpp/native-core"
mkdir -p "$OUT_DIR"
cp "$LIB" "$OUT_DIR/libclashhm_native_core.a"
cp "$HEADER" "$OUT_DIR/native_core.h"

echo "Installed native-core artifact to $OUT_DIR"
