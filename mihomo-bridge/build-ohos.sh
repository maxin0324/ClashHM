#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SDK_ROOT="${OHOS_SDK_ROOT:-${HARMONY_SDK_ROOT:-}}"
if [ -z "$SDK_ROOT" ]; then
  for candidate in \
    "$HOME/command-line-tools/sdk/default" \
    "$HOME/commandline-tools/command-line-tools/sdk/default" \
    "/tmp/ohos-sdk/command-line-tools/sdk/default"; do
    if [ -d "$candidate" ]; then
      SDK_ROOT="$candidate"
      break
    fi
  done
fi

if [ -z "$SDK_ROOT" ] || [ ! -d "$SDK_ROOT" ]; then
  echo "Set OHOS_SDK_ROOT to the HarmonyOS SDK default directory." >&2
  echo "Example: OHOS_SDK_ROOT=/path/to/command-line-tools/sdk/default ./build-ohos.sh" >&2
  exit 1
fi

BISHENG_CC="$SDK_ROOT/hms/native/BiSheng/bin/aarch64-unknown-linux-ohos-clang"
LLVM_CC="$SDK_ROOT/openharmony/native/llvm/bin/clang"
SYSROOT="$SDK_ROOT/openharmony/native/sysroot"

if [ -x "$BISHENG_CC" ]; then
  CC_BIN="$BISHENG_CC"
  CC_TARGET=""
elif [ -x "$LLVM_CC" ]; then
  CC_BIN="$LLVM_CC"
  CC_TARGET="--target=aarch64-linux-ohos"
else
  echo "Cannot find OHOS clang under $SDK_ROOT" >&2
  exit 1
fi

if [ ! -d "$SYSROOT" ]; then
  echo "Cannot find OHOS sysroot under $SYSROOT" >&2
  exit 1
fi

WRAPPER="$(mktemp)"
COMPAT_DIR="$(mktemp -d)"
trap 'rm -f "$WRAPPER"; rm -rf "$COMPAT_DIR"' EXIT
cat >"$WRAPPER" <<EOF
#!/bin/sh
exec "$CC_BIN" $CC_TARGET --sysroot="$SYSROOT" "\$@"
EOF
chmod +x "$WRAPPER"

mkdir -p "$COMPAT_DIR/android" "$COMPAT_DIR/lib"
cat >"$COMPAT_DIR/android/log.h" <<'EOF'
#ifndef OHOS_ANDROID_LOG_H
#define OHOS_ANDROID_LOG_H
#include <stdarg.h>
#define ANDROID_LOG_FATAL 6
int __android_log_vprint(int prio, const char* tag, const char* fmt, va_list ap);
#endif
EOF
cat >"$COMPAT_DIR/log_stub.c" <<'EOF'
#include <stdarg.h>
int __android_log_vprint(int prio, const char* tag, const char* fmt, va_list ap) {
  (void)prio;
  (void)tag;
  (void)fmt;
  (void)ap;
  return 0;
}
EOF
"$CC_BIN" $CC_TARGET --sysroot="$SYSROOT" -c "$COMPAT_DIR/log_stub.c" -o "$COMPAT_DIR/log_stub.o"
ar rcs "$COMPAT_DIR/lib/liblog.a" "$COMPAT_DIR/log_stub.o"

export PATH="${PATH}:/usr/local/go/bin:$HOME/go/bin"
if [ -d "/root/ohos-compat-lib" ]; then
  export LD_LIBRARY_PATH="/root/ohos-compat-lib:$SDK_ROOT/hms/native/BiSheng/lib:${LD_LIBRARY_PATH:-}"
else
  export LD_LIBRARY_PATH="$SDK_ROOT/hms/native/BiSheng/lib:${LD_LIBRARY_PATH:-}"
fi
# Go's linux/arm64 c-shared runtime emits initial-exec ELF TLS, which HarmonyOS
# rejects when the library is loaded through NAPI/dlopen. The Android arm64
# runtime uses a pthread TLS slot instead, while the C parts are still compiled
# and linked with the HarmonyOS clang/sysroot above.
export GOOS=android
export GOARCH=arm64
export CGO_ENABLED=1
export CC="$WRAPPER"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export CGO_CFLAGS="${CGO_CFLAGS:-} -fPIC -I$COMPAT_DIR"
export CGO_LDFLAGS="${CGO_LDFLAGS:-} -L$COMPAT_DIR/lib -Wl,--build-id=none"

echo "=== Using OHOS SDK ==="
echo "SDK_ROOT=$SDK_ROOT"
"$CC_BIN" --version | head -3

echo "=== Fetching dependencies ==="
go mod download

echo "=== Building libmihomo.so (Go Android TLS-slot runtime + OHOS clang) ==="
go build -tags="netgo osusergo" -buildmode=c-shared \
  -buildvcs=false \
  -trimpath \
  -ldflags="-s -w" \
  -o libmihomo.so .

echo "=== Build output ==="
ls -lh libmihomo.so libmihomo.h
file libmihomo.so
readelf -d libmihomo.so | grep -E 'NEEDED|FLAGS' || true
if readelf -l libmihomo.so | grep -q TLS; then
  echo "ERROR: libmihomo.so still contains an ELF TLS segment." >&2
  exit 1
fi

echo "=== Copying to HarmonyOS project ==="
if [ -d "../clash/src/main" ]; then
  for libs_dir in \
    "../clash/src/main/libs/arm64-v8a" \
    "../clash/src/main/libs/arm64"; do
    mkdir -p "$libs_dir"
    cp libmihomo.so "$libs_dir/"
  done
  mkdir -p "../clash/src/main/cpp"
  cp libmihomo.h "../clash/src/main/cpp/"
else
  echo "Skipping project copy: ../clash/src/main was not found."
fi

echo "=== Done ==="
