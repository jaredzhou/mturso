# mturso

This context covers the MoonBit bindings for Turso Database, including local SQL access and synchronization with a remote database.

## Connections

**Connection**:
A single SQL session borrowed from a database; closing it returns it to the database that issued it.
_Avoid_: SyncConnection, raw handle

## Synchronization

**Sync database**:
A local database whose committed changes can be pushed to and pulled from a remote database while retaining local sync history.
_Avoid_: syncdb, embedded replica

**Remote database**:
The authoritative database state behind a sync server; clients synchronize with it through the sync protocol rather than opening a SQL connection to it.
_Avoid_: remote connection, cloud connection

**Sync server**:
The protocol endpoint that hosts a remote database for `push`, `pull`, and related synchronization operations.
_Avoid_: sync backend, remote SQL server

**Bootstrap**:
The initial transfer of a remote database's state into a new, empty sync database.
_Avoid_: initial sync, download

**Push**:
The synchronization direction that sends committed local changes from a sync database to the remote database.
_Avoid_: upload, publish

**Pull**:
The synchronization direction that fetches remote changes and reconciles them with committed local changes.
_Avoid_: download, refresh

**Replay**:
The reapplication of unpushed local changes after remote changes have been applied during `pull`.
_Avoid_: redo, resync

**Checkpoint**:
Compaction of a sync database's local WAL into its main database file while preserving synchronization state.
_Avoid_: flush, vacuum
