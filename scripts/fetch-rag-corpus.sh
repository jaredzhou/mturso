#!/usr/bin/env bash
# 抓取 RAG 演示用的真实文章（古腾堡计划，公有领域），各截取约 1200 词，
# 写入 examples/go-sdk/data/。需要联网。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/examples/go-sdk/data"
mkdir -p "$OUT_DIR"

# extract <id> <out> <词数上限>
# 从 Project Gutenberg 正文起始标记之后开始，截取约 maxw 个词。
extract() {
  local id="$1" out="$2" maxw="$3"
  local url="https://www.gutenberg.org/cache/epub/$id/pg$id.txt"
  echo "抓取并截取：$url -> $out"
  curl -fsL -A "turso-research (RAG demo)" "$url" | awk -v maxw="$maxw" '
    BEGIN { on = 0; done = 0; w = 0 }
    /^\*\*\* START OF/ { on = 1; next }
    on {
      if (done) next
      n = split($0, a, /[ \t]+/)
      for (i = 1; i <= n; i++) if (a[i] != "") w++
      if (w >= maxw) { done = 1; next }
      print
    }
  ' > "$out"
  printf '  %s 行数=%s 词数=%s\n' "$out" "$(wc -l < "$out")" "$(wc -w < "$out")"
}

# 《联邦党人文集》(Gutenberg #1404，公有领域) —— 政论短文
extract 1404 "$OUT_DIR/federalist-papers.txt" 1200

# 《福尔摩斯探案集》(Gutenberg #1661，公有领域) —— 小说
extract 1661 "$OUT_DIR/sherlock-holmes.txt" 1200

echo
ls -la "$OUT_DIR"
