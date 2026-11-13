package main

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	turso "turso.tech/database/tursogo"
	serverless "turso.tech/database/tursogo-serverless"
)

func TestSyncBootstrapFromNativeServer(t *testing.T) {
	remoteURL := os.Getenv("MTURSO_SYNC_URL")
	if remoteURL == "" {
		t.Skip("MTURSO_SYNC_URL is not set")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	remote := sql.OpenDB(serverless.NewConnector(remoteURL, ""))
	defer remote.Close()
	if _, err := remote.ExecContext(
		ctx,
		"CREATE TABLE IF NOT EXISTS native_sync_test(id INTEGER PRIMARY KEY, body TEXT)",
	); err != nil {
		t.Fatal(err)
	}
	if _, err := remote.ExecContext(ctx, "DELETE FROM native_sync_test"); err != nil {
		t.Fatal(err)
	}
	if _, err := remote.ExecContext(
		ctx,
		"INSERT INTO native_sync_test VALUES (1, 'alpha'), (2, 'beta')",
	); err != nil {
		t.Fatal(err)
	}

	syncDB, err := turso.NewTursoSyncDb(ctx, turso.TursoSyncDbConfig{
		Path:              filepath.Join(t.TempDir(), "replica.db"),
		RemoteUrl:         remoteURL,
		ClientName:        "mturso-sync-test",
		LongPollTimeoutMs: 100,
	})
	if err != nil {
		t.Fatal(err)
	}
	conn, err := syncDB.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	rows, err := conn.QueryContext(
		ctx,
		"SELECT body FROM native_sync_test ORDER BY id",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var body string
		if err := rows.Scan(&body); err != nil {
			t.Fatal(err)
		}
		got = append(got, body)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != "alpha" || got[1] != "beta" {
		t.Fatalf("unexpected synced rows: %v", got)
	}
	rows.Close()

	changed, err := syncDB.Pull(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("pull reported changes when the remote revision was unchanged")
	}
	before, err := syncDB.Stats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if before.Revision == "" {
		t.Fatal("stats returned an empty remote revision")
	}

	if _, err := remote.ExecContext(
		ctx,
		"UPDATE native_sync_test SET body = 'beta-updated' WHERE id = 2",
	); err != nil {
		t.Fatal(err)
	}
	changed, err = syncDB.Pull(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("pull did not apply a remote page update")
	}
	var updated string
	if err := conn.QueryRowContext(
		ctx,
		"SELECT body FROM native_sync_test WHERE id = 2",
	).Scan(&updated); err != nil {
		t.Fatal(err)
	}
	if updated != "beta-updated" {
		t.Fatalf("unexpected updated value: %q", updated)
	}

	if _, err := remote.ExecContext(
		ctx,
		"INSERT INTO native_sync_test VALUES (3, 'gamma')",
	); err != nil {
		t.Fatal(err)
	}
	changed, err = syncDB.Pull(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("second incremental pull did not apply the new row")
	}
	var count int
	if err := conn.QueryRowContext(
		ctx,
		"SELECT COUNT(*) FROM native_sync_test",
	).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 3 {
		t.Fatalf("unexpected row count after incremental pulls: %d", count)
	}

	if _, err := remote.ExecContext(
		ctx,
		"UPDATE native_sync_test SET body = 'gamma-updated' WHERE id = 3",
	); err != nil {
		t.Fatal(err)
	}
	if _, err := remote.ExecContext(
		ctx,
		"INSERT INTO native_sync_test VALUES (4, 'delta')",
	); err != nil {
		t.Fatal(err)
	}
	changed, err = syncDB.Pull(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("pull did not merge multiple missed remote revisions")
	}
	var gamma, delta string
	if err := conn.QueryRowContext(
		ctx,
		"SELECT body FROM native_sync_test WHERE id = 3",
	).Scan(&gamma); err != nil {
		t.Fatal(err)
	}
	if err := conn.QueryRowContext(
		ctx,
		"SELECT body FROM native_sync_test WHERE id = 4",
	).Scan(&delta); err != nil {
		t.Fatal(err)
	}
	if gamma != "gamma-updated" || delta != "delta" {
		t.Fatalf("unexpected merged values: gamma=%q delta=%q", gamma, delta)
	}

	after, err := syncDB.Stats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if after.Revision == before.Revision {
		t.Fatal("remote revision did not advance after committed changes")
	}

	logicalDB, err := turso.NewTursoSyncDb(ctx, turso.TursoSyncDbConfig{
		Path:            filepath.Join(t.TempDir(), "logical-replica.db"),
		RemoteUrl:       remoteURL,
		ClientName:      "mturso-logical-fallback-test",
		LogicalMvccPull: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	logicalConn, err := logicalDB.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer logicalConn.Close()
	if err := logicalConn.QueryRowContext(
		ctx,
		"SELECT COUNT(*) FROM native_sync_test",
	).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 4 {
		t.Fatalf("logical fallback replica has %d rows, want 4", count)
	}
}

func TestSyncPushToNativeServer(t *testing.T) {
	remoteURL := os.Getenv("MTURSO_SYNC_URL")
	if remoteURL == "" {
		t.Skip("MTURSO_SYNC_URL is not set")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	syncURL := traceSyncProxy(t, remoteURL)

	remote := sql.OpenDB(serverless.NewConnector(remoteURL, ""))
	defer remote.Close()
	if _, err := remote.ExecContext(
		ctx,
		"CREATE TABLE IF NOT EXISTS native_push_test(id INTEGER PRIMARY KEY, body TEXT)",
	); err != nil {
		t.Fatal(err)
	}
	if _, err := remote.ExecContext(ctx, "DELETE FROM native_push_test"); err != nil {
		t.Fatal(err)
	}
	if _, err := remote.ExecContext(
		ctx,
		"INSERT INTO native_push_test VALUES (1, 'base')",
	); err != nil {
		t.Fatal(err)
	}

	syncDB, err := turso.NewTursoSyncDb(ctx, turso.TursoSyncDbConfig{
		Path:                    filepath.Join(t.TempDir(), "writer.db"),
		RemoteUrl:               syncURL,
		ClientName:              "mturso-push-test",
		PushOperationsThreshold: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	conn, err := syncDB.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, "UPDATE native_push_test SET body = 'local' WHERE id = 1"); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.ExecContext(ctx, "INSERT INTO native_push_test VALUES (2, 'pushed')"); err != nil {
		t.Fatal(err)
	}
	if err := syncDB.Push(ctx); err != nil {
		t.Fatal(err)
	}

	var body string
	var count int
	if err := remote.QueryRowContext(
		ctx,
		"SELECT body FROM native_push_test WHERE id = 1",
	).Scan(&body); err != nil {
		t.Fatal(err)
	}
	if body != "local" {
		t.Fatalf("remote value after push = %q, want local", body)
	}
	if err := remote.QueryRowContext(
		ctx,
		"SELECT COUNT(*) FROM native_push_test",
	).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("remote row count after push = %d, want 2", count)
	}

	replica, err := turso.NewTursoSyncDb(ctx, turso.TursoSyncDbConfig{
		Path:       filepath.Join(t.TempDir(), "replica.db"),
		RemoteUrl:  syncURL,
		ClientName: "mturso-push-replica",
	})
	if err != nil {
		t.Fatal(err)
	}
	replicaConn, err := replica.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer replicaConn.Close()
	if err := replicaConn.QueryRowContext(
		ctx,
		"SELECT body FROM native_push_test WHERE id = 2",
	).Scan(&body); err != nil {
		t.Fatal(err)
	}
	if body != "pushed" {
		t.Fatalf("replica value after pull = %q, want pushed", body)
	}

	if err := syncDB.Push(ctx); err != nil {
		t.Fatalf("empty repeated push failed: %v", err)
	}

	secondWriter, err := turso.NewTursoSyncDb(ctx, turso.TursoSyncDbConfig{
		Path:                    filepath.Join(t.TempDir(), "second-writer.db"),
		RemoteUrl:               syncURL,
		ClientName:              "mturso-push-conflict",
		PushOperationsThreshold: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	secondConn, err := secondWriter.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer secondConn.Close()

	if _, err := conn.ExecContext(
		ctx,
		"UPDATE native_push_test SET body = 'writer-a' WHERE id = 1",
	); err != nil {
		t.Fatal(err)
	}
	if err := syncDB.Push(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := secondConn.ExecContext(
		ctx,
		"UPDATE native_push_test SET body = 'writer-b' WHERE id = 1",
	); err != nil {
		t.Fatal(err)
	}
	if err := secondWriter.Push(ctx); err != nil {
		t.Fatal(err)
	}
	if err := remote.QueryRowContext(
		ctx,
		"SELECT body FROM native_push_test WHERE id = 1",
	).Scan(&body); err != nil {
		t.Fatal(err)
	}
	if body != "writer-b" {
		t.Fatalf("last push did not win: got %q", body)
	}

	tx, err := secondConn.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 80; i++ {
		if _, err := tx.ExecContext(
			ctx,
			fmt.Sprintf(
				"INSERT INTO native_push_test(id, body) VALUES (%d, 'bulk')",
				100+i,
			),
		); err != nil {
			tx.Rollback()
			t.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := secondWriter.Push(ctx); err != nil {
		t.Fatal(err)
	}
	if err := remote.QueryRowContext(
		ctx,
		"SELECT COUNT(*) FROM native_push_test",
	).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 82 {
		t.Fatalf("large transaction row count = %d, want 82", count)
	}
}

func TestSyncPushRetriesAfterLostResponse(t *testing.T) {
	remoteURL := os.Getenv("MTURSO_SYNC_URL")
	if remoteURL == "" {
		t.Skip("MTURSO_SYNC_URL is not set")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	var dropPush atomic.Bool
	dropPush.Store(true)
	proxyURL := lossyPushProxy(t, remoteURL, &dropPush)

	remote := sql.OpenDB(serverless.NewConnector(remoteURL, ""))
	defer remote.Close()
	if _, err := remote.ExecContext(
		ctx,
		"CREATE TABLE IF NOT EXISTS native_retry_test(id INTEGER PRIMARY KEY, body TEXT)",
	); err != nil {
		t.Fatal(err)
	}
	if _, err := remote.ExecContext(ctx, "DELETE FROM native_retry_test"); err != nil {
		t.Fatal(err)
	}
	if _, err := remote.ExecContext(
		ctx,
		"INSERT INTO native_retry_test VALUES (1, 'base')",
	); err != nil {
		t.Fatal(err)
	}

	syncDB, err := turso.NewTursoSyncDb(ctx, turso.TursoSyncDbConfig{
		Path:       filepath.Join(t.TempDir(), "retry.db"),
		RemoteUrl:  proxyURL,
		ClientName: "mturso-push-retry",
	})
	if err != nil {
		t.Fatal(err)
	}
	conn, err := syncDB.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(
		ctx,
		"UPDATE native_retry_test SET body = 'committed' WHERE id = 1",
	); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.ExecContext(
		ctx,
		"INSERT INTO native_retry_test VALUES (2, 'once')",
	); err != nil {
		t.Fatal(err)
	}
	if err := syncDB.Push(ctx); err == nil {
		t.Fatal("push unexpectedly succeeded despite the dropped response")
	}
	if dropPush.Load() {
		t.Fatal("proxy did not forward and drop a push batch")
	}
	var count int
	if err := remote.QueryRowContext(
		ctx,
		"SELECT COUNT(*) FROM native_retry_test",
	).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("first push did not commit remotely before response loss: count=%d", count)
	}
	if err := syncDB.Push(ctx); err != nil {
		t.Fatalf("retry after lost response failed: %v", err)
	}

	var body string
	if err := remote.QueryRowContext(
		ctx,
		"SELECT COUNT(*) FROM native_retry_test",
	).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("retry duplicated rows: count=%d", count)
	}
	if err := remote.QueryRowContext(
		ctx,
		"SELECT body FROM native_retry_test WHERE id = 2",
	).Scan(&body); err != nil {
		t.Fatal(err)
	}
	if body != "once" {
		t.Fatalf("retry changed row unexpectedly: %q", body)
	}
}

func traceSyncProxy(t *testing.T, upstream string) string {
	if os.Getenv("MTURSO_TRACE_SYNC") == "" {
		return upstream
	}
	t.Helper()
	target, err := url.Parse(upstream)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Error(err)
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		t.Logf("sync request %s %s (%d bytes): %s", r.Method, r.URL.Path, len(body), body)
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(server.Close)
	return server.URL
}

func lossyPushProxy(t *testing.T, upstream string, dropPush *atomic.Bool) string {
	t.Helper()
	target, err := url.Parse(upstream)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		request := r.Clone(r.Context())
		request.URL.Scheme = target.Scheme
		request.URL.Host = target.Host
		request.Host = target.Host
		request.RequestURI = ""
		request.Body = io.NopCloser(bytes.NewReader(body))
		response, err := http.DefaultTransport.RoundTrip(request)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer response.Body.Close()
		if strings.Contains(string(body), `"BEGIN IMMEDIATE"`) &&
			dropPush.CompareAndSwap(true, false) {
			http.Error(w, "simulated lost push response", http.StatusServiceUnavailable)
			return
		}
		for key, values := range response.Header {
			for _, value := range values {
				w.Header().Add(key, value)
			}
		}
		w.WriteHeader(response.StatusCode)
		if _, err := io.Copy(w, response.Body); err != nil {
			t.Error(err)
		}
	}))
	t.Cleanup(server.Close)
	return server.URL
}
