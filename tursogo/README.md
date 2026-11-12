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

When the self-hosted server implements `/pull-updates`, extend this directory
with an embedded `tursogo` syncdb smoke test covering bootstrap, push, pull,
checkpoint, and stats.
