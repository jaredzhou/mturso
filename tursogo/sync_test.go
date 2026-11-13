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
