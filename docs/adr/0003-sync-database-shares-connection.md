# SyncDatabase is separate while Connection remains shared

## Status

accepted

## Decision

`Database` and `SyncDatabase` remain separate concrete database facades because they use different native database handles and lifecycle operations. Both return the same public `Connection` type because the sync engine produces the same `turso_connection_t` used by ordinary connections, and prepare, bind, step, rows, and transactions use the same ABI.

`Connection` will not decide whether it came from a plain or sync database. Each facade supplies a private connection lifetime callback that returns the raw connection to its originating pool. `SyncDatabase` owns its own connection pool in the first implementation; common pool internals may be extracted later after the behavior is stable.

## Consequences

- No public `SyncConnection` type and no public `Database` trait are introduced.
- Existing `Database` keeps its name and public API.
- Current `Connection` internals must be decoupled from its concrete `Database` field.
- A private lifetime hook may also drive sync-specific I/O needed while a sync-backed connection is executing SQL.
