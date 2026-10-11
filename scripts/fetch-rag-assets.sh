#!/usr/bin/env bash
# 下载 RAG 演示所需的本地 embedding 资源：
#   - libllama_go.so：kelindar/search 预编译的 llama.cpp 桥接库（purego 调用）
#   - MiniLM-L6-v2.Q8_0.gguf：常见的 sentence-transformers 模型（384 维）
# 需要联网。默认落到仓库内 .cache/rag（可用 TURSO_RAG_ASSETS 覆盖）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${TURSO_RAG_ASSETS:-$REPO_ROOT/.cache/rag}"
mkdir -p "$DIR"

BASE="https://media.githubusercontent.com/media/kelindar/search/main/dist"

fetch() {
  local url="$1" out="$2"
  if [ -s "$out" ]; then
    echo "已存在，跳过：$out"
    return
  fi
  echo "下载 $url"
  curl -fL --retry 3 -A "turso-research" -o "$out.part" "$url"
  mv "$out.part" "$out"
}

fetch "$BASE/linux-x64-avx/libllama_go.so" "$DIR/libllama_go.so"
fetch "$BASE/MiniLM-L6-v2.Q8_0.gguf" "$DIR/MiniLM-L6-v2.Q8_0.gguf"

# 中文语料用的模型：bge-small-zh-v1.5（512 维，f16 GGUF 约 48MB）
fetch "https://huggingface.co/CompendiumLabs/bge-small-zh-v1.5-gguf/resolve/main/bge-small-zh-v1.5-f16.gguf" \
  "$DIR/bge-small-zh-v1.5-f16.gguf"

echo
ls -la "$DIR"
echo
echo "运行示例："
echo "  # 英文语料（MiniLM-L6-v2）"
echo "  cd examples/go-sdk"
echo "  LD_LIBRARY_PATH=$DIR TURSO_RAG_ASSETS=$DIR GOCACHE=/tmp/gocache go run . rag"
echo
echo "  # 中文语料（bge-small-zh-v1.5）"
echo "  LD_LIBRARY_PATH=$DIR TURSO_RAG_ASSETS=$DIR TURSO_RAG_MODEL=$DIR/bge-small-zh-v1.5-f16.gguf TURSO_RAG_DATA=data-zh GOCACHE=/tmp/gocache go run . rag"
