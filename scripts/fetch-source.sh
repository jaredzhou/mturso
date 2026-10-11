#!/usr/bin/env bash
# 拉取与本地引擎对齐的 Turso 源码（默认 tag v0.8.2，可用 TURSO_TAG 覆盖）。
# 需要联网；在本沙箱中需以提权方式执行。
set -euo pipefail

TAG="${TURSO_TAG:-v0.8.2}"
DEST="${TURSO_SRC:-/tmp/turso-src}"
REPO="https://github.com/tursodatabase/turso"

if [ -d "$DEST/.git" ]; then
  echo "更新已有副本：$DEST"
  git -C "$DEST" fetch --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"
  git -C "$DEST" checkout --force "$TAG"
else
  echo "克隆 $REPO @ $TAG -> $DEST"
  git clone --depth 1 --branch "$TAG" "$REPO" "$DEST"
fi

echo "完成：$DEST ($TAG)"
