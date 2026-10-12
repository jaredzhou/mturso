#!/usr/bin/env bash
# 把 Turso 的 C 动态库复制到仓库内 libs/，并把 moon.pkg 里的链接路径改成本仓库路径。
#
# 不需要联网：库随 Go SDK 分发（turso-go-platform-libs），本机拉过一次 Go 依赖就有。
# 也可以手动指定源文件：
#   TURSO_LIB_SRC=/path/to/libturso_sync_sdk_kit.so bash scripts/fetch-turso-lib.sh
#
# 只重写链接路径（库已在仓库内，例如 CI 检出到了别的目录）：
#   bash scripts/fetch-turso-lib.sh --rewrite-only
set -euo pipefail

REWRITE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --rewrite-only) REWRITE_ONLY=1 ;;
    -h | --help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *)
      echo "未知参数: $arg（可用: --rewrite-only）" >&2
      exit 1
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBS_DIR="$REPO_ROOT/libs"
mkdir -p "$LIBS_DIR"

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)  SUB=linux_amd64;  LIB=libturso_sync_sdk_kit.so ;;
  Linux/aarch64) SUB=linux_arm64;  LIB=libturso_sync_sdk_kit.so ;;
  Darwin/x86_64) SUB=darwin_amd64; LIB=libturso_sync_sdk_kit.dylib ;;
  Darwin/arm64)  SUB=darwin_arm64; LIB=libturso_sync_sdk_kit.dylib ;;
  *) echo "不支持的平台: $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac

if [ "$REWRITE_ONLY" -eq 1 ]; then
  if [ ! -f "$LIBS_DIR/$LIB" ]; then
    echo "libs/$LIB 不在仓库里；去掉 --rewrite-only 先复制一次。" >&2
    exit 1
  fi
  echo "只重写链接路径（库已在仓库内: libs/$LIB）"
else
  SRC="${TURSO_LIB_SRC:-}"
  if [ -z "$SRC" ]; then
    MODCACHE="${GOMODCACHE:-$(go env GOMODCACHE 2>/dev/null || true)}"
    SRC="$MODCACHE/github.com/tursodatabase/turso-go-platform-libs@v0.8.2/libs/$SUB/$LIB"
  fi
  if [ ! -f "$SRC" ]; then
    echo "找不到 Turso 库: $SRC" >&2
    echo "请用 TURSO_LIB_SRC=<path> 指定，或先拉取 Go 依赖（go get turso.tech/database/tursogo）。" >&2
    exit 1
  fi
  cp -f "$SRC" "$LIBS_DIR/$LIB"
  echo "已复制: $LIBS_DIR/$LIB"

# macOS：官方 dylib 的 install_name 指向**构建机上**的绝对路径（例如
# /Users/runner/work/.../turso-rs/target/lib-release/deps/libturso_sync_sdk_kit.dylib），
# dyld 会照那条路找，我们写在 cc-link-flags 里的 rpath 就用不上。
# 改成 @rpath/<名字> 让它按 rpath 解析；改了二进制要重新 ad-hoc 签名（Apple Silicon 要求）。
if [ "$(uname -s)" = "Darwin" ]; then
  if command -v install_name_tool >/dev/null 2>&1 && otool -D "$LIBS_DIR/$LIB" 2>/dev/null | grep -q "^/"; then
    install_name_tool -id "@rpath/$LIB" "$LIBS_DIR/$LIB"
    echo "已把 install_name 改成 @rpath/$LIB"
    if command -v codesign >/dev/null 2>&1; then
      codesign --force --sign - "$LIBS_DIR/$LIB" >/dev/null 2>&1 && echo "已重新 ad-hoc 签名"
    fi
  fi
fi
fi

# 只替换 cc-link-flags 那一行的值（链接参数必须挂在根包与 ffi 包两处）
FLAGS="-L$LIBS_DIR -lturso_sync_sdk_kit -Wl,-rpath,$LIBS_DIR"
for pkg in "$REPO_ROOT/moon.pkg" "$REPO_ROOT/ffi/moon.pkg"; do
  [ -f "$pkg" ] || continue
  # GNU sed 与 BSD sed（macOS）的 -i 不一样：BSD 的 -i 会吃掉后面的 -E 当备份后缀。
  if sed --version >/dev/null 2>&1; then
    sed -i -E "s#(\"cc-link-flags\": \")[^\"]*(\")#\1$FLAGS\2#" "$pkg"
  else
    sed -i '' -E "s#(\"cc-link-flags\": \")[^\"]*(\")#\1$FLAGS\2#" "$pkg"
  fi
  echo "已更新: ${pkg#"$REPO_ROOT"/}"
done

echo
echo "验证：moon test --target native"
