# mturso

MoonBit bindings for [Turso](https://turso.tech) — the Rust rewrite of SQLite — built on the official C ABI (`turso.h`), with SQLite-compatible SQL. Linux and macOS today; Windows and WebAssembly are on the way.

![platforms](https://img.shields.io/badge/platforms-linux%20%7C%20macOS%20%7C%20windows%20%28planned%29%20%7C%20wasm%20%28planned%29-lightgrey)
![turso](https://img.shields.io/badge/turso-0.8.2-informational)
![license](https://img.shields.io/badge/license-Apache--2.0-green)

`Database` is a database **and its connection pool**; `Connection` is one checkout from that pool. Queries are typed and streamed row by row, so a large result set never has to be materialised up front. The async API keeps the event loop free while a statement runs.

```moonbit
async fn main {
  let db = @mturso.Database::open(":memory:")
  ignore(db.execute("create table t(id integer primary key, name text)"))
  ignore(db.execute("insert into t(name) values ('alice'), ('bob')"))

  let users : Array[(Int, String)] = db.fetch("select id, name from t order by id")
  println(users)   // [(1, "alice"), (2, "bob")]
  db.close()
}
```

## Features

### Queries

`QueryExecutor` is the entry point (`Connection`, `Database`, and `DbTx` implement it):

- `query(sql, params?) -> &Rows` — typed, streaming rows; `Rows` exposes `has_next` / `get_row` / `columns` / `close`.
- `query_one(sql, params?) -> Row` — the first row, or `NoRows`.
- `execute(sql, params?) -> ExecResult` — affected rows.
- `fetch / fetch_one` — collect rows into `Array[T]` / `T` via `FromRow`.

### Values

- `Value`: `Null | Integer(Int64) | Real(Double) | Text(String) | Blob(Bytes)`.
- `Column { name, decltype }`.
- `ToValue` / `FromValue` / `FromRow`, implemented for `Bool`, all integer widths, `Float` / `Double`, `String`, `Bytes`, `Char`, `Unit`, `Ref`, `Option`, `Json`, `Array` / `Map` (JSON text), `Timestamp`, and tuples up to 5.
- `Row::get[T]` maps through `FromValue`; `Row::value_raw(i)` gives the exact bytes.

### Connection pool

- `Database` **is** the pool: `max_conns`, `connect()` (**async**; waits at the cap), `stats()`, `max_conns()`, `is_closed()`.
- `Database` implements `QueryExecutor` / `TxBeginner`, so `db.query(...)` / `db.execute(...)` / `db.begin_tx()` acquire and release implicitly.
- `Connection` is one checkout; `Connection::close()` returns it to the pool (idempotent).
- `Database::close()` cascades: every connection is closed, then the database is deinited.

### Transactions

- `TxBeginner::begin_tx(opts?) -> DbTx`; `Tx` is just `commit` / `rollback`.
- `TxMode`: `Deferred` / `Immediate` / `Exclusive` / `Concurrent` (`BEGIN CONCURRENT`).
- `DbTx` is one concrete type for both `Connection` and `Database` (it is also a `QueryExecutor`); a pooled `DbTx` returns its connection on commit/rollback.
- `begin_func` commits on success and rolls back on error.

### Async concurrency

- Each `Connection` owns a C-side worker thread; `query` / `execute` await without blocking the MoonBit event loop.
- `max_conns` bounds the number of worker threads; extra `connect()` callers wait.
- `Connection::close()` joins its worker; `Database::close()` cascades to all of them.

### Retries

- `retry_tx` reruns the **whole transaction** on `Busy` or `Conflict`, using full-jitter exponential backoff with an attempts/time budget.
- `RetryOptions { attempts, base_delay_ms, max_delay_ms, budget_ms? }`.

### Errors

- `TursoError`: `ConnectionError` / `QueryError` / `NoRows` / `Busy` / `Conflict`.
- `ValueError`: a value could not be decoded as the requested type.

## Platform support

| Platform / target | Status | Notes |
| --- | --- | --- |
| **Linux x86_64** | ✅ tested | `moon test --target native` green; CI runs it on every push and PR |
| **Linux aarch64** | ✅ tested | CI runs the suite on `ubuntu-24.04-arm` |
| **macOS arm64** | ✅ tested | CI runs the suite on `macos-latest` |
| **Windows x64** | 🚧 planned | Turso ships only a DLL (no import library), so the engine must be loaded at run time; the C stub also needs Win32 threads. Tracked in [#11](https://github.com/jaredzhou/mturso/issues/11) |
| **WebAssembly / edge** | 🚧 planned | Prototyped: the MoonBit module plus a host shim over Turso's wasm build. Tracked in [#10](https://github.com/jaredzhou/mturso/issues/10) |

macOS x86_64 is deliberately absent (MoonBit ships no `darwin-x86_64` toolchain), as is Windows arm64 (the engine's platform-libs package ships a 0-byte placeholder DLL).

## Installation

Not on mooncakes yet, so consume it from source through a **workspace**:

```bash
git clone git@github.com:jaredzhou/mturso.git
cd your-project
moon work init /path/to/mturso .        # put mturso and your module in one workspace
```

Your `moon.mod`:

```toml
import {
  "moonbitlang/async@0.22.4",
  "jaredzhou/mturso@0.1.0",
}
```

Your **root package's** `moon.pkg` — import it, and link the Turso shared library into the final artifact:

```moonbit
import {
  "jaredzhou/mturso",
  "moonbitlang/async",
}

options(
  link: {
    "native": {
      "cc-link-flags": "-L/path/to/mturso/libs -lturso_sync_sdk_kit -Wl,-rpath,/path/to/mturso/libs",
    },
  },
)
```

> MoonBit does not propagate `cc-link-flags` from a dependency to the downstream link, and the link happens in **your** root package. This repo's own `moon.pkg` / `ffi/moon.pkg` already carry the same flags, which is why `moon test` works out of the box.

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
async fn demo(db : @mturso.Database) -> Unit raise @mturso.TursoError {
  let users : Array[(Int, String)] = db.fetch("select id, name from t order by id")
  let one : (Int, String) = db.fetch_one(
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
| `Database::close()` | Idempotent; cascades to every connection, then deinits |
| `Connection::query/query_one/execute` | **async**; typed, streaming rows / `ExecResult` |
| `Connection::fetch/fetch_one` | Typed collection via `FromRow` |
| `Connection::begin_tx(opts?)` | `DbTx` |
| `Connection::close()` | Return the connection to the pool (idempotent) |
| `Connection::last_insert_rowid()/sqlite_version()/is_closed()` | Observability |
| `DbTx::query/query_one/execute` | Run inside the transaction |
| `DbTx::commit()/rollback()` | Finish (once) |
| `TursoError` | `ConnectionError` / `QueryError` / `NoRows` / `Busy` / `Conflict` |

## Known limitations

- **Single-statement `execute`** — `query` rejects multi-statement SQL explicitly; the multi-statement `execute` loop is not enabled yet (it currently trips an engine abort).
- **No cancellation or timeouts** — once submitted, a statement runs to completion (Turso's C ABI has no cross-thread cancel).
- **Native target today** — the binding links a C shared library; Windows and wasm are planned.
- **Preview engine** — Turso 0.8.2 is a preview release with many features behind experimental flags; don't treat it as production SQLite.

## Roadmap

- **#9** — load the engine at run time so consumers don't need to copy link flags.
- **#10** — WebAssembly / edge spike.
- **#11** — Windows x64 (MSVC).

## Development

```bash
moon check --target native      # type check
moon test  --target native      # run the test suite (27 tests)
```

Do not run a bare `moon fmt` over the sources: this toolchain respells `Int` to `Int32`. If you do, revert with `sed -i 's/Int32/Int/g'` on the touched files.

The Turso shared library is vendored in `libs/` (with a `.sha256`), and both `moon.pkg` and `ffi/moon.pkg` point `-L`/rpath at it, so tests need no `LD_LIBRARY_PATH`. On a new machine or after moving the repo:

```bash
bash scripts/fetch-turso-lib.sh   # copies the library + rewrites both link paths
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
