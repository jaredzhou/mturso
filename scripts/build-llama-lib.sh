#!/usr/bin/env bash
# 本地编译 kelindar/search 的 libllama_go.so（llama.cpp 桥接库，供纯 Go 经 purego 调用）。
#
# 为什么需要自己编：官方发行版里预编译的 libllama_go.so 在某些 CPU 上会
# `illegal instruction (SIGILL)` —— 编译时用到了本机不支持的指令。
# 用 -DGGML_NATIVE=OFF 自行编译可生成与当前机器兼容的库。
#
# 需要联网 + cmake + C++ 编译器。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${TURSO_RAG_ASSETS:-$REPO_ROOT/.cache/rag}"
SRC="${TURSO_LLAMA_SRC:-/tmp/ksearch-src}"
JOBS="${JOBS:-4}"
mkdir -p "$DIR"

if [ ! -d "$SRC/.git" ]; then
  echo "克隆 kelindar/search（含 llama.cpp 子模块）到 $SRC"
  git clone --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/kelindar/search "$SRC"
fi

# ccache 在受限环境里可能不可写，直接禁用。
export CCACHE_DISABLE=1

cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF
cmake --build "$SRC/build" -j "$JOBS"

cp "$SRC/build/lib/libllama_go.so" "$DIR/libllama_go.so"
echo "已安装：$DIR/libllama_go.so"
