#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

export PATH=$PATH:/usr/local/go/bin
export CGO_ENABLED=1

echo "=== Fetching dependencies ==="
go mod tidy

echo "=== Building libmihomo.so ==="
go build -buildmode=c-shared \
    -trimpath \
    -ldflags="-s -w" \
    -o libmihomo.so .

echo "=== Build output ==="
ls -lh libmihomo.so libmihomo.h

echo "=== Copying to HarmonyOS project ==="
LIBS_DIR="../clash/src/main/cpp/libs/arm64-v8a"
mkdir -p "$LIBS_DIR"
cp libmihomo.so "$LIBS_DIR/"
cp libmihomo.h "../clash/src/main/cpp/"

echo "=== Done! ==="
echo "libmihomo.so copied to $LIBS_DIR"
