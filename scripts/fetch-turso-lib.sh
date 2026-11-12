#!/usr/bin/env bash
# 把当前平台的 Turso C 动态库复制到仓库内 libs/。
#
# 不需要联网：库随 Go SDK 分发（turso-go-platform-libs），本机拉过一次 Go 依赖就有。
# 也可以手动指定源文件：
#   TURSO_LIB_SRC=/path/to/libturso_sync_sdk_kit.so bash scripts/fetch-turso-lib.sh
set -euo pipefail

case "${1:-}" in
  "") ;;
  -h | --help)
    sed -n '2,6p' "$0"
    exit 0
    ;;
  *)
    echo "未知参数: $1" >&2
    exit 1
    ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBS_DIR="$REPO_ROOT/libs"
mkdir -p "$LIBS_DIR"

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)  SUB=linux_amd64;  LIB=libturso_sync_sdk_kit.so ;;
  Linux/aarch64) SUB=linux_arm64;  LIB=libturso_sync_sdk_kit.so ;;
  Darwin/x86_64) SUB=darwin_amd64; LIB=libturso_sync_sdk_kit.dylib ;;
  Darwin/arm64)  SUB=darwin_arm64; LIB=libturso_sync_sdk_kit.dylib ;;
  MINGW64_NT-*/x86_64 | MSYS_NT-*/x86_64 | CYGWIN_NT-*/x86_64)
    SUB=windows_amd64
    LIB=turso_sync_sdk_kit.dll
    ;;
  MINGW*/aarch64 | MINGW*/arm64 | MSYS*/aarch64 | MSYS*/arm64 | \
    CYGWIN*/aarch64 | CYGWIN*/arm64)
    echo "Windows ARM64 暂不支持：v0.8.2 平台包中的 DLL 是 0 字节占位。" >&2
    exit 1
    ;;
  *) echo "不支持的平台: $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac

SRC="${TURSO_LIB_SRC:-}"
if [ -z "$SRC" ]; then
  MODCACHE="${GOMODCACHE:-$(go env GOMODCACHE 2>/dev/null || true)}"
  if command -v cygpath >/dev/null 2>&1; then
    MODCACHE="$(cygpath -u "$MODCACHE")"
  fi
  SRC="$MODCACHE/github.com/tursodatabase/turso-go-platform-libs@v0.8.2/libs/$SUB/$LIB"
fi
if [ ! -f "$SRC" ]; then
  echo "找不到 Turso 库: $SRC" >&2
  echo "请用 TURSO_LIB_SRC=<path> 指定，或先拉取 Go 依赖（go get turso.tech/database/tursogo）。" >&2
  exit 1
fi

cp -f "$SRC" "$LIBS_DIR/$LIB"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$LIBS_DIR/$LIB" | awk '{print $1}' > "$LIBS_DIR/$LIB.sha256"
else
  shasum -a 256 "$LIBS_DIR/$LIB" | awk '{print $1}' > "$LIBS_DIR/$LIB.sha256"
fi
echo "已复制: $LIBS_DIR/$LIB"
echo "已更新: $LIBS_DIR/$LIB.sha256"

echo
echo "moon.pkg 无需修改；验证：moon test --target native"
