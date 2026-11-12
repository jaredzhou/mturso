# Use the Turso sync engine behind the C ABI for the first client

## Status

accepted

## Decision

The first SyncDatabase implementation will use the official v0.8.2 `turso_sync_*` C ABI as its synchronization state machine. MoonBit will own HTTP, TLS, full-read, and full-write I/O requested by that engine, but will not initially reimplement bootstrap, revision tracking, CDC scanning, WAL replay, or conflict handling.

HTTP and protobuf are transparent enough to replace eventually, but they are only the transport. Reimplementing the client also means owning the persistent sync metadata, main and revert WAL behavior, CDC change selection, rollback-and-replay reconciliation, and page or MVCC stream handling.

## Consequences

- The vendored engine libraries must load the `turso_sync_*` exports and the binding must vendor `turso_sync.h`.
- Sync operations are driven by repeated `resume` calls and must execute queued I/O before resuming again.
- A future protocol-client implementation remains possible, but it is a separate architectural project rather than a prerequisite for usable synchronization.
