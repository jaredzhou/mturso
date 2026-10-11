package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	turso "turso.tech/database/tursogo"
)

// runSync 演示离线优先同步：起一个本地 sync server，演示 bootstrap / push / pull /
// checkpoint / stats。RemoteUrl 用 http(s)://（libsql:// 会被规范化为 https://）。
func runSync() error {
	fmt.Println("\n### sync：本地 sync server + push/pull/checkpoint/stats")

	bin := os.Getenv("TURSODB")
	if bin == "" {
		home, _ := os.UserHomeDir()
		bin = filepath.Join(home, ".turso", "tursodb")
	}
	if _, err := os.Stat(bin); err != nil {
		return fmt.Errorf("找不到 tursodb 可执行文件（可用 TURSODB 指定）: %w", err)
	}

	port, err := freePort()
	if err != nil {
		return err
	}
	baseURL := fmt.Sprintf("http://127.0.0.1:%d", port)

	cmd := exec.Command(bin, "--sync-server", fmt.Sprintf("127.0.0.1:%d", port))
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动 sync server: %w", err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	}()
	if err := waitReady(baseURL, 30*time.Second); err != nil {
		return err
	}
	fmt.Printf("  本地 sync server: %s\n", baseURL)

	ctx := context.Background()
	dir, cleanup, err := tempDir()
	if err != nil {
		return err
	}
	defer cleanup()

	sdb, err := turso.NewTursoSyncDb(ctx, turso.TursoSyncDbConfig{
		Path:       filepath.Join(dir, "local.db"),
		ClientName: "turso-go-demo",
		RemoteUrl:  baseURL,
	})
	if err != nil {
		return err
	}
	db, err := sdb.Connect(ctx)
	if err != nil {
		return err
	}
	defer db.Close()

	// 1) 本地写入 → Push 到远端，再查远端核对。
	if _, err := db.Exec(`create table notes(id integer primary key, body text)`); err != nil {
		return err
	}
	if _, err := db.Exec(`insert into notes(body) values ('from-local-1'), ('from-local-2')`); err != nil {
		return err
	}
	if err := sdb.Push(ctx); err != nil {
		return err
	}
	remoteRows, err := pipeline(baseURL, `select count(*) from notes`)
	if err != nil {
		return err
	}
	fmt.Printf("  本地写 2 行并 Push 后，远端 notes 行数 = %v\n", firstCell(remoteRows))

	// 2) 远端写入 → Pull 到本地，再查本地核对。
	if _, err := pipeline(baseURL, `insert into notes(body) values ('from-remote')`); err != nil {
		return err
	}
	changed, err := sdb.Pull(ctx)
	if err != nil {
		return err
	}
	var localCount int
	if err := db.QueryRow(`select count(*) from notes`).Scan(&localCount); err != nil {
		return err
	}
	fmt.Printf("  远端写 1 行并 Pull（changed=%v）后，本地行数 = %d（期望 3）\n", changed, localCount)

	// 3) Stats 与 Checkpoint（把本地 WAL 落盘）。
	before, err := sdb.Stats(ctx)
	if err != nil {
		return err
	}
	if err := sdb.Checkpoint(ctx); err != nil {
		return err
	}
	after, err := sdb.Stats(ctx)
	if err != nil {
		return err
	}
	fmt.Printf("  Stats: revision=%q cdcOperations=%d\n", after.Revision, after.CdcOperations)
	fmt.Printf("  Checkpoint: MainWalSize %d -> %d, RevertWalSize %d -> %d\n",
		before.MainWalSize, after.MainWalSize, before.RevertWalSize, after.RevertWalSize)
	fmt.Printf("  网络字节: sent=%d received=%d\n", after.NetworkSentBytes, after.NetworkReceivedBytes)
	return nil
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func waitReady(baseURL string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		resp, err := http.Get(baseURL)
		if err == nil {
			resp.Body.Close()
			return nil
		}
		lastErr = err
		time.Sleep(20 * time.Millisecond)
	}
	return fmt.Errorf("sync server 未在 %s 内就绪: %w", timeout, lastErr)
}

// pipeline 通过 sync server 的 /v2/pipeline（SQL-over-HTTP）执行 SQL。
func pipeline(baseURL, sqlText string) ([][]any, error) {
	payload, err := json.Marshal(map[string]any{
		"requests": []map[string]any{{"type": "execute", "stmt": map[string]any{"sql": sqlText}}},
	})
	if err != nil {
		return nil, err
	}
	resp, err := http.Post(baseURL+"/v2/pipeline", "application/json", bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("pipeline HTTP %d: %s", resp.StatusCode, body)
	}
	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, err
	}
	results, _ := result["results"].([]any)
	if len(results) == 0 {
		return nil, fmt.Errorf("pipeline 空响应: %s", body)
	}
	first, _ := results[0].(map[string]any)
	if first["type"] != "ok" {
		return nil, fmt.Errorf("pipeline 非 ok: %s", body)
	}
	respObj, _ := first["response"].(map[string]any)
	resObj, _ := respObj["result"].(map[string]any)
	rowsAny, _ := resObj["rows"].([]any)
	rows := make([][]any, 0, len(rowsAny))
	for _, r := range rowsAny {
		cells, ok := r.([]any)
		if !ok {
			continue
		}
		row := make([]any, 0, len(cells))
		for _, c := range cells {
			if cell, ok := c.(map[string]any); ok {
				row = append(row, cell["value"])
			}
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func firstCell(rows [][]any) any {
	if len(rows) == 0 || len(rows[0]) == 0 {
		return nil
	}
	return rows[0][0]
}
