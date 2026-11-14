# mturso

MoonBit bindings for [Turso](https://turso.tech) — the Rust rewrite of SQLite — built on the official C ABI (`turso.h`), with SQLite-compatible SQL. Linux, macOS, and Windows x64 are supported; WebAssembly is on the way.

![platforms](https://img.shields.io/badge/platforms-linux%20%7C%20macOS%20%7C%20windows%20x64%20%7C%20wasm%20%28planned%29-blue)
![turso](https://img.shields.io/badge/turso-0.8.2-informational)
![license](https://img.shields.io/badge/license-Apache--2.0-green)

`Database` is a database **and its connection pool**; `Connection` is one checkout from that pool. Queries are typed and streamed row by row, so a large result set never has to be materialised up front. The async API keeps the event loop free while a statement runs.

## Quickstart

### Local database

```moonbit
async fn main {
  let db = @mturso.Database::open(":memory:")     // or a file path
  defer db.close()

  ignore(db.execute("create table t(id integer primary key, name text)"))

  // Explicit checkout. `close()` returns the connection to the pool.
  let conn = db.connect()
  defer conn.close()

  ignore(conn.execute(
    "insert into t(name) values (?1), (?2)",
    params=["alice", "bob"],
  ))

  // Pull rows one at a time.
  let rows = conn.query("select id, name from t order by id")
  defer rows.close()
  while rows.has_next() {
    let row = rows.get_row()
    let id : Int = row.get(0)
    let name : String = row.get(1)
    println("\{id}: \{name}")
  }
}
```

### Remote sync

Connect a local replica to a Turso-compatible remote. The first open bootstraps
the replica; later pushes and pulls synchronize changes incrementally.

```moonbit
async fn sync_example() -> Unit raise @mturso.TursoError {
  let config = @mturso.SyncConfig::new(
    "./notes.db",
    remote_url="https://your-database.turso.io",
    auth_token=Some("your-token"),
  )
  let db = @mturso.SyncDatabase::open(config)
  defer db.close()

  let conn = db.connect()
  defer conn.close()

  ignore(
    conn.execute(
      "create table if not exists notes(id integer primary key, body text)",
    ),
  )
  ignore(
    conn.execute(
      "insert into notes(body) values (?1)",
      params=["written locally"],
    ),
  )

  db.push()
  let changed = db.pull()
  let stats = db.stats()
  println("changed=\{changed}, revision=\{stats.revision}")
}
```

## Features

- **SQLite-compatible SQL, in process** — use familiar SQL against file or in-memory databases, with SQLite-compatible storage and no separate database process to manage.
- **Typed queries and safe parameters** — read integers, floats, text, blobs, `NULL`, JSON, and timestamps as native values, stream large result sets, and bind parameters without constructing SQL strings.
- **Async by default** — slow queries and writes run off the MoonBit event loop, while independent connections continue to make progress.
- **Bounded connection pooling** — cap concurrent connections and worker threads, reuse connections automatically, or hold one for a longer unit of work, with contention statistics available.
- **Transactions and contention handling** — use explicit or managed transactions, including deferred, immediate, exclusive, read-only, and MVCC concurrent modes, plus retry helpers for busy locks and write conflicts.
- **Offline-first remote sync** — bootstrap a local replica from a Turso-compatible remote, keep working offline, push local commits, pull incremental changes, and inspect or checkpoint sync state.
- **Self-hosted sync server** — run against the pinned `tursodb` server or this project's native implementation, with SQL access, bootstrap, pull, push, and optional bearer authentication. The server is tested with both this client and the official Go sync client.
- **Runtime-loaded native engine** — Linux x86_64 and Windows x64 packages include the Turso library and load it at runtime, so consumers do not need linker flags; tested macOS arm64 and Linux aarch64 builds fetch the matching library with one script.

## Platform support

| Platform / target | Status | Notes |
| --- | --- | --- |
| **Linux x86_64** | ✅ tested | CI runs the full suite plus local sync-server acceptance against pinned `tursodb` 0.8.2 |
| **Linux aarch64** | ✅ tested | CI runs the suite on `ubuntu-24.04-arm` |
| **macOS arm64** | ✅ tested | CI runs the suite on `macos-latest` |
| **Windows x64** | ✅ tested | MSVC build; CI runs the full suite plus local sync-server acceptance. The DLL is loaded at runtime and workers use Win32 threads plus anonymous pipes |
| **WebAssembly / edge** | 🧪 spike | MoonBit `wasm` + Turso wasm runs end to end under a Node worker host; browser/OPFS and a public API remain planned. See [`notes/wasm-spike.md`](notes/wasm-spike.md) and [#10](https://github.com/jaredzhou/mturso/issues/10) |

macOS x86_64 is deliberately absent (MoonBit ships no `darwin-x86_64` toolchain). Windows ARM64 is unsupported because Turso v0.8.2 ships a 0-byte placeholder DLL in its `windows_arm64` package.

## Installation

Add the package from Mooncakes, pinned to the first release:

```bash
moon add jaredzhou/mturso@0.1.0
```

Or add the dependency directly in your `moon.mod`:

```toml
import {
  "jaredzhou/mturso@0.1.0",
}
```

Your package's `moon.pkg` only needs the import:

```moonbit
import {
  "jaredzhou/mturso",
  "moonbitlang/core/async",
}

options(
  "allow-experimental-packages": [ "moonbitlang/core/async" ],
)
```

### Native dynamic library

The engine is a native shared library loaded at runtime by `ffi/loader.c`. MoonBit
package files therefore need no `link`, `cc-link-flags`, `rpath`, or
`LD_LIBRARY_PATH`.

The platform file names are:

| Platform | File |
| --- | --- |
| Linux x86_64 / aarch64 | `libturso_sync_sdk_kit.so` |
| macOS arm64 | `libturso_sync_sdk_kit.dylib` |
| Windows x64 | `turso_sync_sdk_kit.dll` |

`MTURSO_LIB_PATH` is an explicit file override. When it is unset, the lookup
order is:

1. the `libs/` directory in the mturso source checkout used to build the binding
2. `libs/` beside the executable
3. `./libs/` under the process working directory
4. the platform's normal dynamic-loader search path

For source-workspace development, no environment variable is normally needed.
For another platform or architecture, place the matching library in `libs/`:

```bash
bash scripts/fetch-turso-lib.sh
```

The script only copies the platform library and updates its `.sha256`; it never
changes `moon.pkg`. On Windows, run it from Git Bash or MSYS2.

For a deployed executable, copy the library next to it:

```bash
mkdir -p dist/libs
cp /path/to/mturso/libs/libturso_sync_sdk_kit.so dist/libs/
./dist/your-app
```

On Windows the deployed path is `<exe-dir>\libs\turso_sync_sdk_kit.dll`.

Or point to it explicitly:

```bash
MTURSO_LIB_PATH=/opt/mturso/libturso_sync_sdk_kit.so ./your-app
```

Use the `.dylib` name on macOS. When `MTURSO_LIB_PATH` is set, it is the only
file attempted. A bad path fails immediately with the path and dynamic-loader
error rather than silently loading another copy.

## Usage

### Typed collection with `fetch` / `fetch_one`

```moonbit
async fn demo(conn : @mturso.Connection) -> Unit raise @mturso.TursoError {
  let users : Array[(Int, String)] = conn.fetch("select id, name from t order by id")
  let one : (Int, String) = conn.fetch_one(
    "select id, name from t where id = ?1",
    params=[1],
  )
  println("\{users.length()} users, first = \{one.0}")
}
```

`fetch_one` raises `TursoError::NoRows` when the query returns nothing. Both helpers close the reader for you.

### Values, `NULL` and raw bytes

`Value` has five variants (`Null`, `Integer`, `Real`, `Text`, `Blob`). `Row::value(i)` returns the `Value`; `Row::value_raw(i)` returns the raw bytes (useful for exact `BLOB`/UTF-8 data). MoonBit `String` is UTF-16, while the wire format is UTF-8: conversion happens at the boundary, and invalid UTF-8 is decoded lossily (`U+FFFD`).

### Transactions

```moonbit
async fn demo(db : @mturso.Database) -> Unit raise @mturso.TursoError {
  let conn = db.connect()
  defer conn.close()

  let tx = conn.begin_tx()                 // BEGIN (Deferred)
  ignore(tx.execute("insert into t(name) values ('carol')"))
  tx.commit()

  // Pooled transaction: the connection returns to the pool on commit/rollback.
  let tx2 = db.begin_tx(opts=@mturso.TxOptions::{
    mode: Some(@mturso.TxMode::Concurrent),  // BEGIN CONCURRENT (MVCC only)
    read_only: None,
  })
  ignore(tx2.execute("insert into t(name) values ('dave')"))
  tx2.rollback()
}
```

`begin_func` wraps a whole transaction and commits on success / rolls back on error:

```moonbit
async fn insert_many(db : @mturso.Database) -> Unit raise @mturso.TursoError {
  ignore(@mturso.begin_func(db, async fn(tx) -> Int raise @mturso.TursoError {
    ignore(tx.execute("insert into t(name) values ('eve')"))
    0
  }))
}
```

### Retries

`retry_tx` retries the **whole transaction** on `Busy` (WAL write lock) or `Conflict` (MVCC write-write conflict), with full-jitter backoff. The closure may run more than once — keep it idempotent.

```moonbit
async fn bump(conn : @mturso.Connection) -> Unit raise @mturso.TursoError {
  ignore(@mturso.retry_tx(
    conn,
    async fn(tx) -> Int raise @mturso.TursoError {
      ignore(tx.execute("update t set v = v + 1 where id = 1"))
      0
    },
    opts=@mturso.RetryOptions::{
      attempts: 10,
      base_delay_ms: 1,
      max_delay_ms: 50,
      budget_ms: None,
    },
  ))
}
```

### The pool

```moonbit
async fn demo() -> Unit raise @mturso.TursoError {
  let db = @mturso.Database::open("./app.db", max_conns=4)
  defer db.close()

  ignore(db.execute("create table t(x integer)"))   // implicit acquire/release
  let rows = db.query("select x from t")             // released when `rows.close()`
  defer rows.close()

  let conn = db.connect()                            // explicit checkout (waits at max_conns)
  defer conn.close()                                 // return to the pool

  let st = db.stats()
  println("max=\{(db.max_conns())} acquires=\{st.acquire_count} waits=\{st.acquire_wait_count}")
}
```

### Offline-first sync

`SyncDatabase` keeps a local database synchronized with a Turso Cloud database
or a local `tursodb --sync-server`. SQL still goes through the public
`Connection`; synchronization operations are explicit and serialized.

```moonbit
async fn sync_demo() -> Unit raise @mturso.TursoError {
  let config = @mturso.SyncConfig::new(
    "./local.db",
    remote_url="http://127.0.0.1:8080",
    // auth_token=Some("..."), // required when the remote enables auth
    client_name=Some("my-app"),
    long_poll_timeout_ms=30_000,
  )
  let db = @mturso.SyncDatabase::open(config) // bootstrap if local is empty
  defer db.close()

  let conn = db.connect()
  defer conn.close()
  ignore(conn.execute("insert into notes(body) values ('offline edit')"))
  db.push()

  let changed = db.pull() // true when remote changes were applied
  let stats = db.stats()
  println("revision=\{stats.revision} received=\{stats.network_received_bytes}")
  db.checkpoint()
}
```

`bootstrap_if_empty=false` allows opening without a reachable remote. A later
`push()` or `pull()` reports a structured `TursoError::SyncError`; committed
local changes remain available for retry. `close()` rejects new operations
immediately and finalizes native resources after any in-flight operation ends.

### Error handling

```moonbit
async fn demo(conn : @mturso.Connection) -> Unit raise @mturso.TursoError {
  ignore(conn.query("select * from no_such_table")) catch {
    @mturso.TursoError::QueryError(msg) => println("query failed: \{msg}")
    @mturso.TursoError::ConnectionError(msg) => println("connection: \{msg}")
    @mturso.TursoError::Busy(msg) => println("busy: \{msg}")
    @mturso.TursoError::Conflict(msg) => println("conflict: \{msg}")
    @mturso.TursoError::NoRows => println("no rows")
  }
}
```

## API overview

| API | Description |
| --- | --- |
| `Database::open(path, max_conns?)` | Open a database (file or `":memory:"`); `max_conns` defaults to 4 |
| `Database::connect()` | **async**; take a connection from the pool (waits at `max_conns`) |
| `Database::query/query_one/execute` | Implicit acquire → run → release |
| `Database::begin_tx(opts?)` | Pooled transaction (`DbTx`, released on commit/rollback) |
| `Database::stats()/max_conns()/is_closed()` | Pool observability |
| `Database::set_journal_mode(Wal/Mvcc)/set_default_tx_mode()` | File-level journal mode and default transaction mode |
| `Database::close()` | Idempotent; cascades to every connection, then deinits |
| `SyncConfig::new(path, remote_url~, auth_token?)` | Sync database path, remote URL/token, bootstrap and long-poll settings |
| `SyncDatabase::open(config)` | **async**; open locally and bootstrap when enabled |
| `SyncDatabase::connect()` | **async**; return the same public `Connection` used by local databases |
| `SyncDatabase::push()/pull()/checkpoint()` | **async**; serialize sync operations on one database |
| `SyncDatabase::stats()` | **async**; CDC/WAL/network counters plus opaque remote revision |
| `SyncDatabase::close()` | Idempotent; reject new work, then finalize after an active operation drains |
| `Connection::open(path)` | Convenience connection backed by a private `max_conns=1` database |
| `Connection::query/query_one/execute` | **async**; typed, streaming rows / `ExecResult` |
| `Connection::fetch/fetch_one` | Typed collection via `FromRow` |
| `Row::get/get_by_name/value/value_raw` | Typed, by-name, raw-value, or exact-byte column access |
| `Connection::begin_tx(opts?)` | `DbTx` |
| `Connection::close()` | Return the connection to the pool (idempotent) |
| `Connection::last_insert_rowid()/sqlite_version()/is_closed()` | Observability |
| `DbTx::query/query_one/execute` | Run inside the transaction |
| `DbTx::commit()/rollback()` | Finish (once) |
| `TursoError` | `ConnectionError` / `QueryError` / `NoRows` / `Busy` / `Conflict` / `SyncError` |

## Known limitations

- **No cancellation or timeouts** — once submitted, a statement runs to completion (Turso's C ABI has no cross-thread cancel).
- **Platform boundaries** — native Linux, macOS arm64, and Windows x64 are supported. Windows ARM64 and WebAssembly browser integration are not.
- **Sync scope** — the first sync release supports one remote database and full bootstrap. Partial sync, namespace routing, remote encryption, and multi-database `--sync-dir` are not exposed yet. Sync databases require an explicit `checkpoint()`.
- **Turso Cloud is opt-in** — deterministic CI uses the pinned local `tursodb` server. A real Cloud smoke test requires a database URL and token supplied by the caller.
- **Preview engine** — Turso 0.8.2 is a preview release with many features behind experimental flags; don't treat it as production SQLite.

## Roadmap

- **#10** — WebAssembly / edge spike: minimal Node-host prototype complete; browser-backed API remains planned. See [`notes/wasm-spike.md`](notes/wasm-spike.md).

## Development

```bash
moon check --target native      # type check
moon test  --target native      # run the test suite (62 tests)
```

Do not run a bare `moon fmt` over the sources: this toolchain respells `Int` to `Int32`. If you do, revert with `sed -i 's/Int32/Int/g'` on the touched files.

The sync-server development helpers download the pinned Turso CLI into `.cache/`:

```bash
make download-cli               # fetch and verify tursodb 0.8.2
make native-server              # build the self-hosted pipeline server
make test-server                # lifecycle + native pipeline tests
make server                     # start the self-hosted pipeline server
make server-tursodb             # start the external tursodb sync server
make test-tursogo               # run Go serverless SDK against the running server
```

On Windows, install GNU Make; the `Makefile` locates Git Bash through `git` and
uses it automatically for these targets.

Override `SYNC_DB`, `SYNC_ADDR`, or `TURSODB` when needed. `make server-wrapper`
uses the unified `cmd/server` launcher with external `tursodb`.

`SyncServerConfig` selects the self-hosted native backend by default. The native
backend uses the in-process `jaredzhou/pony@0.7.0` HTTP server and Turso engine.
Both the launcher and the native serving process are the same `cmd/server`
executable; `--serve-native` is its internal serving mode:

```moonbit
let server = @server.SyncServer::start(
  @server.SyncServerConfig::new(
    "./server.db",
    backend=@server.SyncServerBackend::Native,
    native_executable=Some("./server"),
    auth=@server.SyncServerAuth::BearerToken(token),
  ),
)
```

From the CLI, the default mode starts the self-hosted Pony server directly in
the same process, without a launcher. `--tursodb` selects external `tursodb`.
The internal `--serve-native` flag exists only for library-managed
`SyncServer::start(Native)`.

The native backend implements `/v2/pipeline`, `/v3/pipeline`, and
`/v3/cursor`, including batches, conditional steps, positional parameters,
typed rows, BLOB/base64, and per-step errors. It does not yet persist batons for
interactive transactions spanning multiple HTTP requests.

The native server speaks plain HTTP. It listens on loopback by default. Bearer
authentication is enforced by Pony middleware on every sync endpoint:

```text
Authorization: Bearer <token>
```

Set `MTURSO_SYNC_BEARER_TOKEN` when launching the native server directly.
Missing, malformed, and incorrect credentials all receive `401 Unauthorized`.
The static token is compared in constant time, and tokens are never written to
logs or protocol errors. `SyncServerAuth::BearerVerifier` reserves the same
middleware seam for JWT/OIDC verification.

MoonBit does not currently have an HTTPS server implementation for this path,
so the native server deliberately does not accept certificate/private-key
configuration. A public deployment must use a TLS-terminating reverse proxy
such as Caddy or nginx in front of a loopback-bound native server. The proxy is
responsible for the certificate, SAN matching, and preserving the
`Authorization` header. Do not expose the plain HTTP listener directly.

For a proxy in another container or private host, set
`MTURSO_SYNC_EXTERNAL_TLS_PROXY=1`. A non-loopback native bind is rejected
unless that explicit proxy mode and Bearer authentication are both configured:

```powershell
$env:MTURSO_SYNC_BEARER_TOKEN = "<long-random-token>"
$env:MTURSO_SYNC_EXTERNAL_TLS_PROXY = "1"
./server.exe ./server.db 0.0.0.0:8080
```

The external `tursodb --tursodb` backend remains loopback-only and has no
built-in authentication because the pinned CLI does not implement it.

Real Turso Cloud validation is optional because deterministic CI uses the pinned
local server. To smoke-test a Cloud database, provide the URL and token through
the environment and construct `SyncConfig` with them; do not commit or print the
token:

```moonbit
async fn cloud_smoke() -> Unit raise @mturso.TursoError {
  let url = @env.get_env_var("TURSO_SYNC_URL").unwrap_or("")
  let token = @env.get_env_var("TURSO_AUTH_TOKEN").unwrap_or("")
  if url == "" || token == "" {
    fail("set TURSO_SYNC_URL and TURSO_AUTH_TOKEN")
  }
  let db = @mturso.SyncDatabase::open(@mturso.SyncConfig::new(
    "./cloud-smoke.db",
    remote_url=url,
    auth_token=Some(token),
  ))
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(conn.execute("select 1"))
}
```

The Linux x86_64 and Windows x64 Turso libraries are vendored in `libs/` with
SHA-256 files. They are loaded at runtime, so neither the repo nor a consumer
needs `-L`, `-l`, an rpath, or `LD_LIBRARY_PATH`. On another platform or
architecture, fetch the matching library; the script only copies files and
does not edit `moon.pkg`:

```bash
bash scripts/fetch-turso-lib.sh
```

Layout:

| Path | Contents |
| --- | --- |
| `mturso.mbt` | `Database` (pool) and `Connection` |
| `value/` | `Value`, `Column` |
| `traits.mbt` / `values.mbt` | value traits, `Row`, `QueryExecutor`, built-in impls |
| `rows.mbt` | streaming `Rows` reader + frame parsing |
| `tx.mbt` / `retry.mbt` | transactions and retry helpers |
| `pool.mbt` | `PoolStats` + `Database`'s pool-side impls |
| `sync.mbt` | `SyncDatabase`, operation driver, and MoonBit-owned sync I/O |
| `server/` | shared external/native `SyncServer` facade and lifecycle |
| `cmd/server/` | unified external/native sync-server launcher and Pony HTTP adapter |
| `ffi/` | `extern "c"` declarations + thin C stub + vendored Turso headers |
| `design/` | Compiler-checked design spec (`moon check` clean) |
| `libs/` | The Turso C shared library |
| `notes/` | Research notes on the Turso engine |
| `examples/` | Go SDK examples and a C ABI worker skeleton |

## License

Apache-2.0
