# tursogo-serverless smoke test

This module verifies that the self-hosted mturso server works with Turso's
official `turso.tech/database/tursogo-serverless` Go SDK.

The SDK source under `sdk/` is vendored from Turso tag `v0.8.2`
(`serverless/go`) because that release does not publish the subdirectory as a
standalone `v0.8.2` Go module.

Start the default self-hosted server:

```powershell
cd C:\Users\jared\projects\mturso
make server
```

Then run the Go smoke test from another terminal:

```powershell
cd C:\Users\jared\projects\mturso\tursogo
go run . -url http://127.0.0.1:8080
```

Expected output:

```text
tursogo-serverless: ok
```

The test covers DDL, parameter binding, TEXT, BLOB, `ExecContext`, the v3 cursor
endpoint, and `QueryRowContext(...).Scan`.

## Sync bootstrap smoke test

`sync_test.go` uses the embedded official `turso.tech/database/tursogo` client
against the native server's `/pull-updates` endpoint. It verifies page
bootstrap, local queries, an unchanged empty pull, and sync stats.

Run it with the repository helper, which starts and stops the native server:

```powershell
make test-tursogo-sync
```

The test skips when `MTURSO_SYNC_URL` is unset, so the normal `go test ./...`
does not require a running server. Push, checkpoint, and multi-replica sync
will be added with their server tickets.
