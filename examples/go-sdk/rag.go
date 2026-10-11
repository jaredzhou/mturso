package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"

	"github.com/kelindar/search/llama"
)

// runRAG 演示一个最小 RAG 场景，中英文语料都支持：
//  1. 用本地 embedding 模型对真实文章分块嵌入：
//     英文用 all-MiniLM-L6-v2（384 维），中文用 bge-small-zh-v1.5（512 维）；
//  2. 把向量以 vector32 blob 存进 Turso，用 vector_distance_cos 做最近邻检索；
//  3. 用检索到的片段拼出上下文（RAG 的「检索 → 增强」）。
//
// 环境变量：
//
//	TURSO_RAG_ASSETS  模型/动态库目录（默认 ../../.cache/rag）
//	TURSO_RAG_MODEL   具体 GGUF 模型路径（默认 <assets>/MiniLM-L6-v2.Q8_0.gguf）
//	TURSO_RAG_DATA    语料目录（默认 data；中文语料用 data-zh）
//	TURSO_RAG_QUERIES 自定义查询，用 | 分隔
func runRAG() error {
	fmt.Println("\n### rag：本地 embedding + Turso 向量检索")

	assets := os.Getenv("TURSO_RAG_ASSETS")
	if assets == "" {
		assets = filepath.Join("..", "..", ".cache", "rag")
	}
	modelPath := os.Getenv("TURSO_RAG_MODEL")
	if modelPath == "" {
		modelPath = filepath.Join(assets, "MiniLM-L6-v2.Q8_0.gguf")
	}
	if _, err := os.Stat(modelPath); err != nil {
		return fmt.Errorf("找不到模型 %s（先运行 scripts/fetch-rag-assets.sh）: %w", modelPath, err)
	}

	dataDir := os.Getenv("TURSO_RAG_DATA")
	if dataDir == "" {
		dataDir = "data"
	}
	files, err := filepath.Glob(filepath.Join(dataDir, "*.txt"))
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return fmt.Errorf("%s 下没有语料（先运行 scripts/fetch-rag-corpus*.sh）", dataDir)
	}

	// 1) 加载 embedding 模型（llama.cpp，纯 Go 经 purego 调用）
	model, err := llama.New(modelPath, 0) // 0 = 只用 CPU
	if err != nil {
		return fmt.Errorf("加载模型失败（是否设置了 LD_LIBRARY_PATH 指向 libllama_go.so？）: %w", err)
	}
	defer model.Close()
	ctx := context.Background()

	// 2) 分块 + 嵌入。CJK 语料按「字符」计预算，英文按等价字符数。
	var docs []ragDoc
	cjkCorpus := false
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		if isCJK(string(raw)) {
			cjkCorpus = true
		}
		docs = append(docs, ragDoc{name: strings.TrimSuffix(filepath.Base(f), ".txt"), text: string(raw)})
	}
	maxRunes := 700 // 英文约 110 词
	if cjkCorpus {
		maxRunes = 220 // 中文约 220 字（bge-zh 上限 512 token）
	}

	var chunks []ragChunk
	for _, d := range docs {
		for i, c := range chunkText(d.text, maxRunes) {
			chunks = append(chunks, ragChunk{doc: d.name, seq: i, text: c})
		}
	}
	embeddings := make([][]float32, len(chunks))
	dim := 0
	for i, c := range chunks {
		vec, err := model.EmbedText(ctx, c.text)
		if err != nil {
			return fmt.Errorf("嵌入第 %d 块失败: %w", i, err)
		}
		embeddings[i] = vec
		dim = len(vec)
	}
	fmt.Printf("  模型：%s\n", filepath.Base(modelPath))
	fmt.Printf("  语料：%d 个片段（来自 %d 个文件），embedding 维度 = %d，块上限 = %d 字符\n",
		len(chunks), len(files), dim, maxRunes)

	// 3) 存进 Turso：向量以 vector32 blob 存储，检索用 vector_distance_cos
	db, err := sql.Open("turso", ":memory:")
	if err != nil {
		return err
	}
	defer db.Close()
	if _, err := db.Exec(`create table chunks(id integer primary key, doc text, seq integer, text text, emb blob)`); err != nil {
		return err
	}
	insert, err := db.Prepare(`insert into chunks(doc, seq, text, emb) values (?, ?, ?, vector32(?))`)
	if err != nil {
		return err
	}
	defer insert.Close()
	for i, c := range chunks {
		lit, err := json.Marshal(embeddings[i])
		if err != nil {
			return err
		}
		if _, err := insert.Exec(c.doc, c.seq, c.text, string(lit)); err != nil {
			return err
		}
	}

	// 4) 检索：查询先嵌入，再在 Turso 里做最近邻
	for _, q := range ragQueries(cjkCorpus) {
		qv, err := model.EmbedText(ctx, q)
		if err != nil {
			return err
		}
		lit, err := json.Marshal(qv)
		if err != nil {
			return err
		}
		rows, err := db.Query(`
			select doc, seq, text, vector_distance_cos(emb, vector32(?)) as d
			from chunks order by d limit 3`, string(lit))
		if err != nil {
			return err
		}
		fmt.Printf("\n  查询：%s\n", q)
		var top []string
		for rows.Next() {
			var (
				doc  string
				seq  int
				text string
				d    float64
			)
			if err := rows.Scan(&doc, &seq, &text, &d); err != nil {
				rows.Close()
				return err
			}
			fmt.Printf("    [%s#%02d] cos_dist=%.4f  %s\n", doc, seq, d, snippet(text, 60))
			top = append(top, text)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}

		// 5) 拼出给 LLM 的上下文（RAG 的「增强」步骤）
		if len(top) > 0 {
			fmt.Println("    --- 组装给 LLM 的上下文 ---")
			fmt.Printf("    问：%s\n    参考：\n", q)
			for i, t := range top {
				fmt.Printf("      %d. %s\n", i+1, snippet(t, 120))
			}
		}
	}
	return nil
}

type ragDoc struct {
	name string
	text string
}

// ragChunk 是一个分块片段。
type ragChunk struct {
	doc  string
	seq  int
	text string
}

// ragQueries 返回默认查询；可用 TURSO_RAG_QUERIES（| 分隔）覆盖。
func ragQueries(cjk bool) []string {
	if q := os.Getenv("TURSO_RAG_QUERIES"); q != "" {
		return strings.Split(q, "|")
	}
	if cjk {
		return []string{
			"精衛填海講的是什麼故事？",
			"孔子怎樣談論學習與仁德？",
			"書中記載了哪些上古山川與神獸？",
		}
	}
	return []string{
		"Should the people adopt the proposed plan of government?",
		"What did Holmes deduce about the King of Bohemia's case?",
		"How are the powers of the federal government divided?",
	}
}

// isCJK 判断文本是否以中日韩字符为主。
func isCJK(s string) bool {
	cjk, total := 0, 0
	for _, r := range s {
		if unicode.IsSpace(r) {
			continue
		}
		total++
		if unicode.Is(unicode.Han, r) || unicode.Is(unicode.Hiragana, r) || unicode.Is(unicode.Katakana, r) {
			cjk++
		}
		if total > 4000 {
			break
		}
	}
	return total > 0 && float64(cjk)/float64(total) > 0.3
}

var (
	reSpaces   = regexp.MustCompile(`\s+`)
	reCJKSpace = regexp.MustCompile(`([\p{Han}\p{Hiragana}\p{Katakana}，。！？、；：」』）】])\s+([\p{Han}\p{Hiragana}\p{Katakana}，。！？、；：」『（【])`)
)

// chunkText 把文本切成约 maxRunes 个「字符」的块：按句子聚合，超长片段硬切。
// 以字符（rune）衡量，因此对中文（无空格）同样适用；兼容 \r\n 换行。
func chunkText(text string, maxRunes int) []string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	flat := reSpaces.ReplaceAllString(text, " ")
	// 去掉中文之间被换行引入的多余空格
	for i := 0; i < 4; i++ {
		flat = reCJKSpace.ReplaceAllString(flat, "$1$2")
	}

	var chunks []string
	var cur []rune
	for _, s := range splitSentences(flat) {
		rs := []rune(s)
		if len(cur) > 0 && len(cur)+len(rs) > maxRunes {
			chunks = append(chunks, string(cur))
			cur = nil
		}
		cur = append(cur, rs...)
	}
	if len(cur) > 0 {
		chunks = append(chunks, string(cur))
	}

	var out []string
	for _, c := range chunks {
		out = append(out, hardWrap(c, maxRunes)...)
	}
	return out
}

// splitSentences 以中英文句读为界切句（终止符与其后的空白/引号并入前一句）。
func splitSentences(s string) []string {
	r := []rune(s)
	var out []string
	start := 0
	for i := 0; i < len(r); i++ {
		if !isSentenceEnd(r[i]) {
			continue
		}
		j := i + 1
		for j < len(r) && (r[j] == ' ' || r[j] == '"' || r[j] == '”' || r[j] == '」' || r[j] == '』') {
			j++
		}
		out = append(out, string(r[start:j]))
		start = j
		i = j - 1
	}
	if start < len(r) {
		out = append(out, string(r[start:]))
	}
	return out
}

func isSentenceEnd(c rune) bool {
	switch c {
	case '.', '!', '?', '。', '！', '？', '；', ';':
		return true
	}
	return false
}

// hardWrap 把超长文本按字符数上限硬切成多块。
func hardWrap(s string, maxRunes int) []string {
	r := []rune(s)
	if len(r) <= maxRunes {
		return []string{s}
	}
	var out []string
	for i := 0; i < len(r); i += maxRunes {
		end := i + maxRunes
		if end > len(r) {
			end = len(r)
		}
		out = append(out, string(r[i:end]))
	}
	return out
}

func snippet(s string, n int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) <= n {
		return string(r)
	}
	return string(r[:n]) + "…"
}
