#!/usr/bin/env bash
# 抓取中文 RAG 语料（古腾堡计划，公有领域），从正文起始标记后截取约 N 个字符，
# 写入 examples/go-sdk/data-zh/。需要联网。
#
# 中文没有空格分隔，所以按「字符数」而不是词数截取。
set -euo pipefail
export LC_ALL=C.UTF-8   # 让 awk/wc 按字符计数

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/examples/go-sdk/data-zh"
mkdir -p "$OUT_DIR"

# extract <id> <out> <字符数上限>
extract() {
  local id="$1" out="$2" maxc="$3"
  local url="https://www.gutenberg.org/cache/epub/$id/pg$id.txt"
  echo "抓取并截取：$url -> $out"
  curl -fsL -A "turso-research (RAG demo)" "$url" | awk -v maxc="$maxc" '
    BEGIN { on = 0; done = 0; c = 0 }
    /^\*\*\* START OF/ { on = 1; next }
    on {
      if (done) next
      if ($0 ~ /^(Produced by|Credits:|Updated editions|Character set encoding|Language:|Title:|Release date:|Other information)/) next
      c += length($0)
      if (c >= maxc) { done = 1; next }
      print
    }
  ' > "$out"
  printf '  %s 行数=%s 字符数=%s\n' "$out" "$(wc -l < "$out")" "$(wc -m < "$out")"
}

# 《山海經》(Gutenberg #25288，公有领域) —— 上古神话与地理
extract 25288 "$OUT_DIR/shanhaijing.txt" 3000

# 《論語》(Gutenberg #23839，公有领域) —— 儒家语录
extract 23839 "$OUT_DIR/lunyu.txt" 3000

echo
ls -la "$OUT_DIR"
