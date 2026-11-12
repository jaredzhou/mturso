#!/usr/bin/env bash
# Download and verify the pinned tursodb CLI used by sync-server tests and make server.
set -euo pipefail

VERSION="${TURSODB_VERSION:-0.8.2}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${TURSODB_CACHE:-$REPO_ROOT/.cache/tursodb/$VERSION}"
mkdir -p "$DEST_DIR"

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) ASSET=turso_cli-x86_64-unknown-linux-gnu.tar.xz; BIN=tursodb ;;
  Linux/aarch64 | Linux/arm64) ASSET=turso_cli-aarch64-unknown-linux-gnu.tar.xz; BIN=tursodb ;;
  Darwin/x86_64) ASSET=turso_cli-x86_64-apple-darwin.tar.xz; BIN=tursodb ;;
  Darwin/arm64) ASSET=turso_cli-aarch64-apple-darwin.tar.xz; BIN=tursodb ;;
  MINGW64_NT-*/x86_64 | MSYS_NT-*/x86_64 | CYGWIN_NT-*/x86_64)
    ASSET=turso_cli-x86_64-pc-windows-msvc.zip
    BIN=tursodb.exe
    ;;
  *)
    echo "unsupported tursodb platform: $(uname -s)/$(uname -m)" >&2
    exit 1
    ;;
esac

DEST="$DEST_DIR/$BIN"
if [ -x "$DEST" ] && "$DEST" --version 2>/dev/null | grep -q "$VERSION"; then
  echo "$DEST"
  exit 0
fi

BASE_URL="https://github.com/tursodatabase/turso/releases/download/v$VERSION"
tmp="$(mktemp -d)"
archive="$tmp/$ASSET"

if [ -n "${TURSODB_CLI_ARCHIVE:-}" ]; then
  cp -f "$TURSODB_CLI_ARCHIVE" "$archive"
else
  curl -fsSL "$BASE_URL/$ASSET" -o "$archive"
  curl -fsSL "$BASE_URL/$ASSET.sha256" -o "$archive.sha256"
  expected="$(awk 'NR == 1 { print $1 }' "$archive.sha256")"
  actual="$(sha256sum "$archive" | awk '{ print $1 }')"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "tursodb checksum mismatch for $ASSET" >&2
    exit 1
  fi
fi

case "$ASSET" in
  *.zip) unzip -q "$archive" -d "$tmp" ;;
  *.tar.xz) tar -xJf "$archive" -C "$tmp" ;;
esac

source_bin="$(find "$tmp" -type f -name "$BIN" | head -n1)"
if [ -z "$source_bin" ]; then
  echo "$BIN not found in $ASSET" >&2
  exit 1
fi
cp -f "$source_bin" "$DEST"
chmod +x "$DEST"

if ! "$DEST" --version | grep -q "$VERSION"; then
  echo "downloaded tursodb is not v$VERSION: $DEST" >&2
  exit 1
fi

echo "$DEST"
