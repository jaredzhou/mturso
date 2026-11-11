# AGENTS.md

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues (`jaredzhou/mturso`), driven with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels (`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` / `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

single-context: root `CONTEXT.md` + `docs/adr/`. See `docs/agents/domain.md`.

## What this repo is

This repo holds the **MoonBit binding for Turso** (`jaredzhou/mturso`) plus a set of **research notes** on the Turso engine that feed it. Two goals:

1. **Usage** — drive the Turso engine / SQL shell locally and through client SDKs, and expose it to MoonBit.
2. **Implementation** — read the engine source and write down how it works (storage, WAL, MVCC, vector search, full-text index, sync, MCP, …).

Background: Turso is a **Rust rewrite of SQLite**; upstream is `github.com/tursodatabase/turso` (early codename *limbo* — `limbo_*` symbols are still in the code). It is highly compatible with SQLite's file format and SQL dialect, and layers a set of experimental features on top.

## The binding: `jaredzhou/mturso`

- Module name `jaredzhou/mturso` (`moon.mod`), **native-only** (it links against Turso's C ABI).
- `mturso.mbt` is the facade; **FFI is its own package**: `ffi/` (`ffi.mbt` holds the `extern "c"` declarations, `stub.c` is the C implementation, `turso.h` is the vendored C ABI header).
- Current state: `Database::open` → many `Connection`s (`db.connect()`); `query` / `exec` are **async** (one worker thread + doorbell pipe per connection, so the event loop never blocks), plus synchronous `query_blocking` / `exec_blocking`. Design notes: `notes/turso-binding-guide.md` §6.
- Public naming: the module is `mturso`, but **names inside the library use the `Turso` prefix** — the error type is `TursoError` (mirroring moonpg's `PgError`), the diagnostic scalar function is `turso_sleep(ms)`. Two exceptions: the C stub's `mturso_*` symbols stay as they are (`turso_*` is the engine's own C ABI namespace), and `@mturso` is the import path.
- **`design/` holds the compiler-checked design spec** for the next version: `declare` declarations plus `usage_*.mbt` snippets (ordinary functions, not `test`, because the API is unimplemented). `moon check --target native` must stay clean there. `design/README.md` records the call-shape gotchas found while writing it.
- `README.md` is **English** (GitHub-facing, standard library README). The notes, `design/README.md` and `docs/agents/*` stay in Chinese.
- MoonBit toolchain: **0.1.20261012** (core `0.10.15`), dependency `moonbitlang/async@0.22.4`. Note async 0.22.4 needs the new core (older cores lack `eprintln`) — the toolchain was upgraded via `moon upgrade`, and CI installs the latest, so the two move together.
- **Write `Int`, and do not run a bare `moon fmt` over the sources.** `Int` and `Int32` are the same type here (`moon info` prints `Int`), but the 0.1.20261012 formatter unconditionally respells `Int` → `Int32`, there is no moonfmt flag to keep `Int`, and toolchains older than that release cannot parse `Int32` at all. We prefer `Int`, so CI runs `moon fmt --warn` (prints the diff, does not fail) instead of `--check`; if you do run `moon fmt`, revert the respelling (`sed -i 's/Int32/Int/g'` on the touched files) before committing.
- After touching FFI or the C stub you must run: `moon check --target native`, `moon test --target native`; finish with `moon fmt && moon info` (and check the `pkg.generated.mbti` diff).

## Environment (measured 2026-10-11 — re-verify before relying on it)

- **tursodb 0.8.2**: `/home/jared/.turso/tursodb` (already on `PATH` via `~/.turso/env`). It is **both the engine and an interactive SQL shell**.
  - `select sqlite_version();` returns `3.50.4`. That is a **compatibility disguise**, not proof that it is SQLite.
- **Go**: `go1.27.1` (was 1.26.4; upgraded because `kelindar/search/llama` requires go 1.27 — `go env -w GOTOOLCHAIN=go1.27.1`), `GOPROXY=https://proxy.golang.org,direct`.
- **Network is blocked inside the sandbox by default** (`go get` / `git clone` / downloads fail, and the proxy port returns `operation not permitted`), but **works with escalation (`require_escalated`)**. Anything that needs the network must either be escalated or marked "needs network verification" in the notes.
- Already on disk: a copy of the Turso source (`/tmp/turso-src`, tag **v0.8.2**; `scripts/fetch-source.sh` re-fetches it), `turso.tech/database/tursogo` in the Go module cache (**v0.8.2**) plus its prebuilt native libraries, and RAG assets (MiniLM GGUF under `.cache/rag/` + a locally built `libllama_go.so`).
- Already on disk (MoonBit side): a copy of `moonbitlang/async` **v0.22.4** (`/tmp/async-0224`; re-fetch with `git clone --branch v0.22.4 https://github.com/moonbitlang/async`); the `moon` toolchain is at `/home/jared/.moon/bin/moon`. The user's own PG driver lives at `/home/jared/projects/moonpg` (pinned to `moonbitlang/async@0.19.0` — **do not upgrade its dependencies**).
- Still missing locally: the `turso` cloud CLI, a `sqlite3` binary.
- The sandbox refuses destructive commands such as `rm -f`; create temp dirs with `mktemp -d` and leave cleanup to the user.
- **git**: the repo is a real git repo (`origin` = `git@github.com:jaredzhou/mturso.git`, branch `main`) — but `.git` is read-only inside the sandbox, so `git add` / `commit` / `push` / `fetch` need escalation. Push with `git push origin main`.

## Layout conventions

- **The MoonBit module (repo root)**: `moon.mod` (module `jaredzhou/mturso`), `moon.pkg` (root package; no engine link flags), `mturso.mbt` (facade), `mturso_test.mbt` (black-box tests), `pkg.generated.mbti` (generated by `moon info`, commit it).
- `ffi/` — **a separate FFI package**: `moon.pkg` (native-stub), `ffi.mbt` (raw `extern "c"`), `stub.c` (C implementation + runtime engine loader), `turso.h` (vendored C ABI header), `pkg.generated.mbti`.
- `libs/` — the Turso C shared library checked into the repo (`libturso_sync_sdk_kit.so`, **20 MB**) plus its `.sha256`. `ffi/stub.c` loads it at runtime; `scripts/fetch-turso-lib.sh` only copies the platform library and hash, never edits `moon.pkg`. (If you would rather not version a 20 MB blob, add `libs/` to `.gitignore` and fetch it on demand.)
- `_build/` — MoonBit build output, **never commit** (already in `.gitignore`).
- `docs/agents/` — the agent-skills config (issue tracker, triage labels, domain docs layout).
- `notes/` — research notes, **one topic per file** (`architecture.md`, `source-walkthrough.md`, `go-sdk.md`, `turso-binding-guide.md`, `wasm-spike.md`).
- `examples/` — runnable examples: `examples/tursodb-basics.sh` (CLI), `examples/go-sdk/` (Go SDK), `examples/c-abi-worker/` (minimal C ABI "worker thread + doorbell" skeleton, ~150 lines, measured).
- `spike/wasm-browser/` — runnable MoonBit `wasm` + Turso wasm + Node worker prototype for ticket #10. It is a research spike, not part of the published native module.
- `scripts/` — helper scripts: `fetch-source.sh` (clone the matching engine source), `fetch-turso-lib.sh` (copy the platform C library + hash), `fetch-rag-assets.sh` (model), `fetch-rag-corpus.sh` / `fetch-rag-corpus-zh.sh` (English / Chinese corpora), `build-llama-lib.sh` (native embedding library).
- Root files: `AGENTS.md`, `README.md`.
- Temp databases always go in a `mktemp -d` directory; **never commit `*.db` / `*.db-log` / `*.db-wal`**. Same for Go artifacts (`examples/go-sdk/*.db`, module caches).

## Commit conventions

- **Commit messages are written in English**, even though the notes and design docs are Chinese. Subject line in the imperative, prefixed with a conventional type: `feat:` / `fix:` / `docs:` / `refactor:` / `test:` / `ci:` / `chore:`. Mark breaking changes to the public API with `!` (e.g. `refactor!: ...`) and explain the migration in the body.
- Put the reasoning and the verification you ran in the body — future sessions read commit bodies as much as the code.
- One logical change per commit; keep `moon check --target native --deny-warn` and `moon test --target native --deny-warn` green before committing.

## Common commands (all verified)

```bash
# --- the MoonBit binding (jaredzhou/mturso) ---
moon check --target native                  # type check
moon test  --target native                  # → Total tests: 28, passed: 28
moon fmt && moon info                       # format + regenerate pkg.generated.mbti

# version
/home/jared/.turso/tursodb --version            # Turso 0.8.2

# one statement against an in-memory database
/home/jared/.turso/tursodb :memory: "select 1+1;"

# several statements against a file database (pretty table output by default)
d=$(mktemp -d)
/home/jared/.turso/tursodb "$d/demo.db" \
  "create table t(id integer primary key, name text);
   insert into t(name) values ('alice'),('bob');
   select * from t;"

# output modes: pretty (default) / list / line
/home/jared/.turso/tursodb -m list :memory: "select 1 as a, 2 as b;"

# interactive shell meta-commands (leading dot)
printf '.help\n.quit\n' | /home/jared/.turso/tursodb "$d/demo.db"

# full example
bash examples/tursodb-basics.sh
```

Other run modes: `--mcp` (built-in MCP server), `--sync-server <addr>` / `--sync-dir <path>` (sync service), `-v/--vfs <io_uring|memory|syscall>`. These **listen on ports or load local files** — don't start them unless the task calls for it.

## Research conventions

- Every claim about internals must be **traceable**: cite a source path, or the command that produced the evidence (e.g. extracting strings from the binary).
- Notes distinguish three levels: **measured** (actually ran it), **source/binary evidence** (path or command cited), **inferred** (explicitly labelled as such). Anything unverifiable gets `TODO(verify)`.
- Example scripts must run as-is with `bash`; anything that doesn't run doesn't belong in `examples/`.
- Use `rg` for searching text and filenames.

## Research roadmap (backlog)

1. **Go SDK** ✅: module `turso.tech/database/tursogo` (driver name `turso`). The comprehensive example `examples/go-sdk/` (subcommands `basic` / `cdc` / `vector` / `concurrent` / `mvcc` / `conflict` / `retry` / `sync` / `rag`) all runs, covering CDC, a WAL concurrent-write comparison (single-connection baseline, busy-wait switch, lock handoff and CPU cost measurements), MVCC `BEGIN CONCURRENT` and write-write conflict semantics, retry-budget measurements, vector search, push/pull/checkpoint/stats against a local `tursodb --sync-server`, and RAG. Open: a real Turso Cloud remote + token, and measuring `experimental=` / `async=1` / encryption options.
2. **Source walkthrough** ✅ (first pass): summarised against tag v0.8.2 along the pipeline (parse → translate → VDBE → execute) plus the storage/concurrency layers — see `notes/source-walkthrough.md`.
3. **Feature deep dives** (in progress): vector search, FTS (tantivy-based), JSON/JSONB, custom types, materialized views (incremental/DBSP), CDC, encryption at rest, the sync protocol, the MCP server, the Postgres frontend.
4. **RAG demo** ✅: the `rag` subcommand in `examples/go-sdk/` — chunk and embed real articles (Gutenberg, public domain) with a local embedding model → store them in Turso vectors → nearest-neighbour retrieval → assemble the context. English uses MiniLM-L6-v2 (`data/`), Chinese uses bge-small-zh-v1.5 (`data-zh/`).
5. **MoonBit binding v0.2** (planned): implement the `design/` spec — typed values, parameter binding, materialized row sets, transaction objects, retry helpers, connection pool. The work is broken into tickets in GitHub Issues; the spec is issue #1.
6. **WASM spike** ✅: MoonBit `wasm` → synchronous host ABI → Node worker → `@tursodatabase/database-wasm` end-to-end demo, with size/memory measurements and implementation slices in `notes/wasm-spike.md`. Browser and OPFS remain `TODO(verify)`.

## Gotchas

- **The Turso engine is loaded at runtime**: `ffi/stub.c` resolves the C ABI with `dlopen`/`dlsym`, so `moon.pkg` files carry no `-L`, `-l`, rpath, or other engine link flags. `MTURSO_LIB_PATH` is an explicit file override; otherwise lookup is `<mturso-source>/libs/` → `<exe>/libs/` → `./libs/` → the system loader path. A downstream module that only imports mturso must build and run without repeating link flags.
- Turso's C shared library is vendored in `libs/` (originally from the Go SDK's `turso-go-platform-libs@v0.8.2`; `nm -D` shows it exports 77 `turso_*` symbols). `scripts/fetch-turso-lib.sh` replaces it for the current platform when needed but does not modify package metadata.
- C-side conventions (`ffi/stub.c`): **never return NULL to MoonBit** (failures are reported through `mturso_last_error()`, where an empty string means success); handles are external objects with finalizers; **never mix `step` and `execute` on the same statement**.
- MoonBit side: **you cannot add methods to a type owned by another package** (`Cannot define method ... for foreign type`) — so the facade defines its own struct wrapping the `@ffi` handle.
- **Network is blocked**: don't design steps that need it without saying so.
- The Go build cache defaults to `~/.cache/go-build` (not writable in the sandbox): run Go examples with `GOCACHE=/tmp/gocache go run .`.
- `go build ./...` can fail with `error obtaining VCS status` (the `.git` directory used to be an empty dir): add `-buildvcs=false`.
- `tursodb` is a preview engine; many features sit behind `--experimental-*` flags (views, custom-types, vacuum, attach, without-rowid, multiprocess-wal, …). **Don't assume parity with production SQLite.**
- Don't bind `--sync-server` / `--mcp` to a public address.
