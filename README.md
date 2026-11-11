# mturso

MoonBit bindings for [Turso](https://turso.tech) — the Rust rewrite of SQLite — built on the official C ABI (`turso.h`), with SQLite-compatible SQL. Linux and macOS today; Windows and WebAssembly are on the way.

![platforms](https://img.shields.io/badge/platforms-linux%20%7C%20macOS%20%7C%20windows%20%28planned%29%20%7C%20wasm%20%28planned%29-lightgrey)
![turso](https://img.shields.io/badge/turso-0.8.2-informational)
![license](https://img.shields.io/badge/license-Apache--2.0-green)

`Database` is a database **and its connection pool**; `Connection` is one checkout from that pool. Queries are typed and streamed row by row, so a large result set never has to be materialised up front. The async API keeps the event loop free while a statement runs.

```moonbit
async fn main {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  ignore(db.execute("create table t(id integer primary key, name text)"))
  ignore(db.execute("insert into t(name) values ('alice'), ('bob')"))

  let conn = db.connect()
  defer conn.close()
  let users : Array[(Int, String)] = conn.fetch("select id, name from t order by id")
  println(users)   // [(1, "alice"), (2, "bob")]
}
```

## Features

- **Query APIs with explicit result shapes** — `query` returns a pull-based `Rows` reader for row-by-row iteration; `query_one` returns exactly one `Row` (or `NoRows`); both expose columns through the `FromValue` decoding contract. `execute` is the DDL/DML entry point and returns `ExecResult` with affected rows. The call site always says whether you want rows, one row, or only execution status.
- **Bind values safely with `ToValue`** — pass `params=[...]` and let `ToValue` encode integers, floats, strings, blobs, options, JSON, timestamps and tuples; `FromValue` / `FromRow` decode them back. No SQL string building.
- **Built-in connection pool** — `Database` is the pool: `max_conns` caps concurrency, `db.query` / `db.execute` borrow a connection automatically, `db.connect()` checks one out explicitly, and `db.stats()` shows contention.
- **First-class transactions** — `begin_tx` / `commit` / `rollback`, with `Deferred`, `Immediate`, `Exclusive`, and Turso's `BEGIN CONCURRENT`; `begin_func` commits on success and rolls back on error.
- **Async without blocking the event loop** — every connection runs on its own external C worker thread, so a slow query never freezes the MoonBit event loop; `max_conns` keeps that thread budget under control.
- **Retries that understand contention** — `retry_tx` reruns a whole transaction on `Busy` (WAL write lock) or `Conflict` (MVCC write-write), with full-jitter backoff and a bounded budget.
- **Errors you can match on** — `TursoError` separates connection, query, no-rows, busy, and conflict failures.
- **Deterministic shutdown** — `close()` joins worker threads, and `db.close()` cascades to every pooled connection.
- **No separate engine install** — the Turso library ships with the binding and is loaded at runtime; consumers never write linker flags.

## Platform support

| Platform / target | Status | Notes |
| --- | --- | --- |
| **Linux x86_64** | ✅ tested | `moon test --target native` green; CI runs it on every push and PR |
| **Linux aarch64** | ✅ tested | CI runs the suite on `ubuntu-24.04-arm` |
| **macOS arm64** | ✅ tested | CI runs the suite on `macos-latest` |
| **Windows x64** | 🚧 planned | Turso ships only a DLL (no import library), so the engine must be loaded at run time; the C stub also needs Win32 threads. Tracked in [#11](https://github.com/jaredzhou/mturso/issues/11) |
| **WebAssembly / edge** | 🧪 spike | MoonBit `wasm` + Turso wasm runs end to end under a Node worker host; browser/OPFS and a public API remain planned. See [`notes/wasm-spike.md`](notes/wasm-spike.md) and [#10](https://github.com/jaredzhou/mturso/issues/10) |

macOS x86_64 is deliberately absent (MoonBit ships no `darwin-x86_64` toolchain), as is Windows arm64 (the engine's platform-libs package ships a 0-byte placeholder DLL).

## Installation

Not on mooncakes yet, so consume it from source through a **workspace**:

```bash
git clone git@github.com:jaredzhou/mturso.git
cd your-project
moon work init /path/to/mturso .        # put mturso and your module in one workspace
```

If the project already has a workspace, add mturso to it instead:

```bash
moon work use /path/to/mturso
```

Your `moon.mod`:

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

The engine is a native shared library loaded at runtime by `ffi/stub.c`. MoonBit
package files therefore need no `link`, `cc-link-flags`, `rpath`, or
`LD_LIBRARY_PATH`.

The platform file names are:

| Platform | File |
| --- | --- |
| Linux x86_64 / aarch64 | `libturso_sync_sdk_kit.so` |
| macOS arm64 | `libturso_sync_sdk_kit.dylib` |
| Windows x64 | `turso_sync_sdk_kit.dll` (vendored; Win32 stub pending #11) |

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
changes `moon.pkg`.

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

## Quickstart

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
| `Connection::open(path)` | Convenience connection backed by a private `max_conns=1` database |
| `Connection::query/query_one/execute` | **async**; typed, streaming rows / `ExecResult` |
| `Connection::fetch/fetch_one` | Typed collection via `FromRow` |
| `Row::get/get_by_name/value/value_raw` | Typed, by-name, raw-value, or exact-byte column access |
| `Connection::begin_tx(opts?)` | `DbTx` |
| `Connection::close()` | Return the connection to the pool (idempotent) |
| `Connection::last_insert_rowid()/sqlite_version()/is_closed()` | Observability |
| `DbTx::query/query_one/execute` | Run inside the transaction |
| `DbTx::commit()/rollback()` | Finish (once) |
| `TursoError` | `ConnectionError` / `QueryError` / `NoRows` / `Busy` / `Conflict` |

## Known limitations

- **Multi-statement `execute` (DML)** — `query` rejects multi-statement SQL; `execute` runs multiple DML statements in order. A script that mixes DDL and a later write in one call can trip an engine bug (a `btree` panic), so run DDL as its own `execute`.
- **No cancellation or timeouts** — once submitted, a statement runs to completion (Turso's C ABI has no cross-thread cancel).
- **Native target today** — the binding loads a C shared library at runtime; Windows and wasm are planned.
- **Preview engine** — Turso 0.8.2 is a preview release with many features behind experimental flags; don't treat it as production SQLite.

## Roadmap

- **#10** — WebAssembly / edge spike: minimal Node-host prototype complete; browser-backed API remains planned. See [`notes/wasm-spike.md`](notes/wasm-spike.md).
- **#11** — Windows x64 (MSVC).

## Development

```bash
moon check --target native      # type check
moon test  --target native      # run the test suite (36 tests)
```

Do not run a bare `moon fmt` over the sources: this toolchain respells `Int` to `Int32`. If you do, revert with `sed -i 's/Int32/Int/g'` on the touched files.

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
| `ffi/` | `extern "c"` declarations + thin C stub + vendored `turso.h` |
| `design/` | Compiler-checked design spec (`moon check` clean) |
| `libs/` | The Turso C shared library |
| `notes/` | Research notes on the Turso engine |
| `examples/` | Go SDK examples and a C ABI worker skeleton |

## License

Apache-2.0
