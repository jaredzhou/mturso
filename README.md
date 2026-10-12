# mturso

MoonBit bindings for [Turso](https://turso.tech) — the Rust rewrite of SQLite — built on the official C ABI (`turso.h`). Native target, SQLite-compatible SQL.

![target](https://img.shields.io/badge/target-native-blue)
![turso](https://img.shields.io/badge/turso-0.8.2-informational)
![license](https://img.shields.io/badge/license-Apache--2.0-green)

`Database` is a connection factory; `Connection` runs SQL. Every connection owns a dedicated **C-side worker thread**, and queries are **async**: statements run on that thread, so the MoonBit event loop never blocks.

```moonbit
let db = @mturso.Database::open(":memory:")
let conn = db.connect()
ignore(conn.exec("create table t(id integer primary key, name text)"))
ignore(conn.exec("insert into t(name) values ('alice'), ('bob')"))
println(conn.query("select id, name from t order by id"))   // 1\talice\n2\tbob
conn.close()
db.close()
```

## Features

- **One database, many connections** — call `db.connect()` as often as you like; each connection has its own statement/transaction state and its own worker thread.
- **Queries don't block the event loop** — blocking happens on the connection's worker thread; a doorbell pipe wakes the awaiting task when the statement finishes.
- **SQLite-compatible** — `select sqlite_version()` reports `3.50.4`; DDL/DML and `begin`/`commit`/`rollback` work as you would expect.
- **Blocking API available** — `query_blocking` / `exec_blocking` run on the calling thread, no async runtime required.
- **Engine included** — the Turso shared library ships with the repo (`libs/`, ~20 MB); no separate engine install.

## Installation

Not on mooncakes yet, so consume it from source through a **workspace** (this flow is verified end to end):

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

> Why you have to write that yourself: MoonBit does not propagate `cc-link-flags` from a dependency's `moon.pkg` to the downstream link, and the link happens in **your** root package. This repo's own `moon.pkg` / `ffi/moon.pkg` already carry the same flags, which is why `moon test` works out of the box; consumers need their own copy (replace `/path/to/mturso` with the real path).

## Quickstart

Async (recommended — queries never block the event loop):

```moonbit
async fn main {
  let db = @mturso.Database::open(":memory:")     // or a file path: "./demo.db"
  let conn = db.connect()

  ignore(conn.exec("create table t(id integer primary key, name text)"))
  ignore(conn.exec("insert into t(name) values ('alice'), ('bob')"))

  println(conn.query("select id, name from t order by id"))
  // 1	alice
  // 2	bob

  conn.close()
  db.close()
}
```

No async runtime needed:

```moonbit
fn main raise @mturso.TursoError {
  let db = @mturso.Database::open(":memory:")
  let conn = db.connect()
  ignore(conn.exec_blocking("create table t(x integer)"))
  ignore(conn.exec_blocking("insert into t values (1), (2)"))
  println(conn.query_blocking("select sum(x) from t"))   // 3
  conn.close()
  db.close()
}
```

## Usage

### One database, many connections

Connections on the same database see each other's committed work:

```moonbit
async fn demo() -> Unit raise @mturso.TursoError {
  let db = @mturso.Database::open(":memory:")
  let c1 = db.connect()
  let c2 = db.connect()

  ignore(c1.exec("create table t(id integer primary key, v integer)"))
  ignore(c1.exec("insert into t(v) values (1), (2)"))

  println(c2.query("select count(*) from t"))   // 2 — same database, other connection
  ignore(c2.exec("insert into t(v) values (3)"))
  println(c1.query("select count(*) from t"))   // 3

  c1.close()
  c2.close()
  db.close()
}
```

### Concurrency: a slow query doesn't block another connection

One worker thread per connection, so a 2-second query on one connection leaves the other connection free:

```moonbit
async fn demo() -> Unit raise @mturso.TursoError {
  let db = @mturso.Database::open(":memory:")
  let slow = db.connect()
  let fast = db.connect()
  let fast_ms : Ref[Int64] = { val: 0L, }

  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(slow.query("select turso_sleep(2000)"))   // sleeps 2s on its own thread
    })
    @async.sleep(100)                                  // let the slow query start
    let t = @async.now()
    ignore(fast.query("select 6 * 7"))
    fast_ms.val = @async.now() - t
  })

  println("fast query took \{fast_ms.val}ms (slow one still running)")   // measured: 1ms
  slow.close()
  fast.close()
  db.close()
}
```

`turso_sleep(ms)` is a diagnostic scalar function the binding registers on every connection (not an engine builtin): it sleeps on **the thread executing that statement**, which makes it easy to stage a slow query from SQL.

### Transactions

A transaction is ordinary SQL pinned to one connection; other connections never see rolled-back work:

```moonbit
async fn demo() -> Unit raise @mturso.TursoError {
  let db = @mturso.Database::open(":memory:")
  let c1 = db.connect()
  let c2 = db.connect()
  ignore(c1.exec("create table t(id integer primary key, v integer)"))

  ignore(c1.exec("begin"))
  ignore(c1.exec("insert into t(v) values (1)"))
  ignore(c1.exec("commit"))
  println(c2.query("select count(*) from t"))   // 1

  ignore(c1.exec("begin"))
  ignore(c1.exec("insert into t(v) values (2)"))
  ignore(c1.exec("rollback"))
  println(c2.query("select count(*) from t"))   // 1

  c1.close()
  c2.close()
  db.close()
}
```

### Error handling

Every database error surfaces as `@mturso.TursoError`, carrying the engine's message:

```moonbit
async fn demo(conn : @mturso.Connection) -> Unit raise @mturso.TursoError {
  try {
    ignore(conn.query("select * from no_such_table"))
  } catch {
    @mturso.TursoError(msg) => println("turso: \{msg}")
  }
}
```

## API overview

| API | Description |
| --- | --- |
| `Database::open(path)` | Open a file database, or `":memory:"` |
| `Database::connect()` | Open a connection (one C-side worker thread each) |
| `Database::close()` | Close the database (idempotent) |
| `Connection::query(sql)` | **async**; run a single query, returns tab-separated text |
| `Connection::exec(sql)` | **async**; run DDL/DML, returns affected rows (`Int64`) |
| `Connection::query_blocking(sql)` / `exec_blocking(sql)` | Synchronous variants, no async runtime |
| `Connection::close()` | Close the connection and reclaim its worker thread (idempotent) |
| `TursoError` | The single error type; the engine message comes out of `catch` |

## Known limitations

- **No parameter binding yet** — values must be written into SQL as literals; positional `params?` lands in the next version.
- **Results are still text** — `query` returns a tab-separated string, with `NULL` rendered as `NULL` and `BLOB` as `<blob>`; there is no typed accessor yet.
- **No cancellation or timeouts** — once submitted, a statement runs to completion (Turso's C ABI has no cross-thread cancel).
- **Native only** — it depends on a C shared library, so wasm/js targets are not supported.
- **Preview engine** — Turso 0.8.2 is a preview release with many features behind experimental flags; don't treat it as production SQLite.

## Roadmap

Typed values (`Value` / `Column`), parameter binding, materialized row sets (`Rows` / `Row`), real transaction objects (`Tx` / `begin_tx`, including `BEGIN CONCURRENT`), retry helpers (`retry_tx` / `retry_stmt`) and a connection pool (`Pool`) are already written as a compiler-checked design spec (`design/`, `moon check` clean). They land in this order: value subpackage → typed C-side buffering → traits → pool + retry, shaped to match [`jaredzhou/moonpg`](https://github.com/jaredzhou/moonpg).

## Development

```bash
moon check --target native      # type check
moon test  --target native      # run the test suite (6 tests)
moon fmt && moon info           # format + regenerate pkg.generated.mbti
```

The Turso shared library is vendored in `libs/` (with a `.sha256`), and both `moon.pkg` and `ffi/moon.pkg` point `-L`/rpath at it, so tests need no `LD_LIBRARY_PATH`. On a new machine or after moving the repo, run:

```bash
bash scripts/fetch-turso-lib.sh   # copies the library + rewrites both link paths
```

Layout:

| Path | Contents |
| --- | --- |
| `mturso.mbt` | Public API: `Database`, `Connection`, `TursoError` |
| `ffi/` | FFI layer: `extern "c"` declarations + C stub (per-connection worker thread, doorbell pipe) + vendored `turso.h` |
| `design/` | Design spec for the next version (`declare` declarations plus usage snippets; `moon check` clean) |
| `libs/` | The Turso C shared library |
| `notes/` | Research notes on the Turso engine (source walkthrough, Go SDK measurements, binding-dev reference) — unrelated to the library API |
| `examples/` | Go SDK examples and a C ABI worker-thread skeleton (research) |

## License

Apache-2.0
