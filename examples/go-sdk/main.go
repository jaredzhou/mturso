// Turso Go SDK 综合示例：覆盖 driver、CDC、向量检索、并发写、MVCC、同步。
//
// 用法：
//
//	go run . basic        driver 基础：CRUD / 参数绑定 / 事务提交与回滚
//	go run . cdc          变更数据捕获 PRAGMA capture_data_changes_conn
//	go run . vector       向量检索：vector32 + 距离函数，最近邻查询
//	go run . concurrent   并发写（WAL）：多连接并行 + busy timeout
//	go run . mvcc         MVCC：journal_mode=mvcc + BEGIN CONCURRENT 并行写
//	go run . conflict     MVCC 写写冲突：改同一条记录时为何「立即报错」而不是等待
//	go run . retry        MVCC 重试预算实测（争用强度 / 退避策略 vs 所需尝试次数）
//	go run . sync         同步：起本地 sync server，演示 push/pull/checkpoint/stats
//	go run . rag          RAG：本地 MiniLM 嵌入真实文章 → Turso 向量检索 → 组装上下文
//	go run . all          依次运行 basic/cdc/vector/concurrent/mvcc
//
// 说明：
//   - SDK 为 turso.tech/database/tursogo（driver 名 "turso"）；首次 go mod tidy 需联网。
//   - 沙箱内构建缓存不可写，请用 GOCACHE=/tmp/gocache go run .
//   - sync 需要监听本地端口，须在有网络权限的环境下运行。
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("用法: go run . <basic|cdc|vector|concurrent|mvcc|conflict|retry|sync|rag|all>")
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "basic":
		err = runBasic()
	case "cdc":
		err = runCDC()
	case "vector":
		err = runVector()
	case "concurrent":
		err = runConcurrent()
	case "mvcc":
		err = runMVCC()
	case "conflict":
		err = runConflict()
	case "retry":
		err = runRetry()
	case "sync":
		err = runSync()
	case "rag":
		err = runRAG()
	case "all":
		for _, fn := range []func() error{runBasic, runCDC, runVector, runConcurrent, runMVCC, runConflict} {
			if err = fn(); err != nil {
				break
			}
		}
	default:
		fmt.Fprintf(os.Stderr, "未知命令: %s\n", os.Args[1])
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "错误: %v\n", err)
		os.Exit(1)
	}
}

// tempDir 创建临时目录，并返回清理函数。
func tempDir() (string, func(), error) {
	dir, err := os.MkdirTemp("", "turso-go-")
	if err != nil {
		return "", nil, err
	}
	return dir, func() { _ = os.RemoveAll(dir) }, nil
}
