package main

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
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

	changed, err := syncDB.Pull(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("pull reported changes when the remote revision was unchanged")
	}
	stats, err := syncDB.Stats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if stats.Revision == "" {
		t.Fatal("stats returned an empty remote revision")
	}
}
