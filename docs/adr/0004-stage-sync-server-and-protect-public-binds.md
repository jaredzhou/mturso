# Stage the sync server and protect public binds

## Status

accepted

## Decision

The first `SyncServer` implementation manages a pinned external `tursodb --sync-server` process found through `TURSODB` or `PATH`. It binds only to loopback and uses plain HTTP without authentication; it is a development and test backend, not a public deployment mode.

The later native, protocol-compatible server will use MoonBit's HTTP/TLS server support with a native server-engine bridge. It will remain loopback by default. A non-loopback bind requires both HTTPS with explicit certificate and private-key files and authentication with a static Bearer token or verifier callback. Public TLS certificates must carry the configured domain or IP in their SAN; automatic certificate issuance is out of scope.

## Consequences

- Server startup must reject unsafe public configurations instead of warning and continuing.
- The external-server implementation must verify Turso v0.8.2 before launching it.
- The future server stage keeps the same public facade while replacing its backend.
- TLS certificate files and bearer secrets must never be logged.
