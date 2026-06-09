#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_CORE_DIR="$ROOT_DIR/clash/src/main/cpp/native-core"
LIB="$NATIVE_CORE_DIR/libclashhm_native_core.a"
HEADER="$NATIVE_CORE_DIR/native_core.h"

if [[ ! -f "$HEADER" ]]; then
  echo "Missing native-core header: $HEADER" >&2
  exit 2
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi
}

PARTS=()
while IFS= read -r part; do
  PARTS+=("$part")
done < <(find "$NATIVE_CORE_DIR" -maxdepth 1 -type f -name 'libclashhm_native_core.a.part*' | sort)

if [[ "${#PARTS[@]}" -eq 0 ]]; then
  echo "Missing native-core split parts: $NATIVE_CORE_DIR/libclashhm_native_core.a.partNN" >&2
  exit 2
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
RECONSTRUCTED="$WORK_DIR/libclashhm_native_core.a"
cat "${PARTS[@]}" > "$RECONSTRUCTED"

if [[ -f "$LIB" ]]; then
  if ! cmp -s "$LIB" "$RECONSTRUCTED"; then
    echo "Native-core split parts do not reconstruct the checked-out full archive." >&2
    echo "Full archive sha256:" >&2
    sha256_file "$LIB" >&2
    echo "Reconstructed sha256:" >&2
    sha256_file "$RECONSTRUCTED" >&2
    exit 1
  fi
else
  cp "$RECONSTRUCTED" "$LIB"
fi

echo "native_core_header=$HEADER"
echo "native_core_archive=$LIB"
echo "native_core_parts=${#PARTS[@]}"
sha256_file "$LIB"
