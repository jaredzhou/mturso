# Go SDK 接入笔记（已实测）

> 状态：**已实测跑通**（2026-10-11）。综合示例见 `examples/go-sdk/`（`basic` / `cdc` / `vector` /
> `concurrent` / `mvcc` / `sync` / `rag` 七条子命令），输出见文末。
> 本环境网络默认被沙箱阻断，但**提权（escalate）后可联网**，因此首次拉依赖需要联网一步。

## 用哪个 SDK

| 体系 | 模块 | 驱动名 | 说明 |
| --- | --- | --- | --- |
| **新引擎（推荐）** | `turso.tech/database/tursogo` | `turso` | 本仓库研究的 Rust 引擎的官方 Go SDK。**随引擎仓库 `bindings/go` 一起发布**，版本与引擎同步（实测 `v0.8.2`）。无 CGO，用 [purego](https://github.com/ebitengine/purego) 调 Rust 的 C ABI。预编译原生库来自 `github.com/tursodatabase/turso-go-platform-libs`。 |
| 旧独立仓库 | `github.com/tursodatabase/turso-go` | `turso` | 早期版本（`v0.2.x`），仓库内自带 `libs/` 预编译库，且带 GORM 支持。新项目用上面的 `tursogo`。 |
| libSQL / Turso Cloud（另一套） | `github.com/tursodatabase/libsql-client-go`、`github.com/tursodatabase/go-libsql` | `libsql` | 面向**旧的 libSQL/远端 Hrana 协议**（HTTP/WebSocket）与嵌入式副本，和上面基于新引擎的本地库不是同一回事，别混用。 |

结论：**要对接本仓库的引擎，用 `turso.tech/database/tursogo`，驱动名 `turso`。**

## 最小用法

```go
import (
    "database/sql"
    _ "turso.tech/database/tursogo"
)

db, err := sql.Open("turso", ":memory:")          // 或本地文件路径 "app.db"
defer db.Close()

db.Exec(`create table t(id integer primary key, name text)`)
stmt, _ := db.Prepare(`insert into t(name) values (?)`)
stmt.Exec("alice")

rows, _ := db.Query(`select id, name from t`)
```

## DSN / 连接串

形如 `<path>[?选项]`，`path` 可为 `:memory:` 或本地文件路径。选项（源码 `bindings/go/driver_db.go: parseDSN`）：

| 选项 | 说明 |
| --- | --- |
| `experimental=<string>` | 开启实验特性（对应 CLI 的 `--experimental-*`） |
| `async=0\|1` | 异步 I/O |
| `vfs=<string>` | 选择 VFS |
| `encryption_cipher=` / `encryption_hexkey=` | 静态加密 |
| `_busy_timeout=<ms>` | 忙等待超时，默认 5000；`-1` 表示禁用 |

## 同步（remote sync，离线优先）

本地已用**官方 sync server**（`tursodb --sync-server`）端到端验证：bootstrap、Push、Pull、
Checkpoint、Stats 都跑通（`go run . sync`）。Turso Cloud 只是换成一个 https 远端 + auth token：

```go
turso "turso.tech/database/tursogo"

db, err := turso.NewTursoSyncDb(ctx, turso.TursoSyncDbConfig{
    Path:      "local.db",
    RemoteUrl: "https://<db>.<region>.turso.io",
    AuthToken: "<token>",
})
// 之后 db.Connect(ctx) / db.Push(ctx) / db.Pull(ctx) / db.Checkpoint(ctx) / db.Stats(ctx)
```

Push/Pull 与 Checkpoint 不能并发跑（wrapper 内部有 mutex）。参考上游示例 `examples/go/sync/sync.go`。

**关于首次同步的报错** `no such table: turso_sync_last_change_id`：不是故障。同步引擎在数据库里维护
内部状态表 `turso_sync_last_change_id`；客户端第一次同步会先读它，而表还没建 → 服务端 batch 执行器把
该 step 记为失败并打 ERROR，客户端据此按「无历史状态」bootstrap，随后 `CREATE TABLE IF NOT EXISTS` 建表。
实测同一服务端连做 3 次同步，该报错只出现 1 次。示例每次都能看到，是因为它启动的 sync server 默认
`:memory:`（`--sync-server` 未带 DATABASE），每次都等于首次同步；用 `--sync-dir <dir>` 给持久库即可消除。

## 公开 API 全貌

底层 `turso_*` 绑定函数**未导出**，外部可用入口：`sql.Open("turso", dsn)` 驱动、
`NewConnector` + `WithBusyTimeout`、`Setup`、以及同步的 `NewTursoSyncDb` /
`TursoSyncDbConfig` / `TursoSyncDbStats` / `Connect|Pull|Push|Stats|Checkpoint`。
详细清单见 `examples/go-sdk/README.md`。

## 事务 / MVCC 的关键事实（实测 + 源码）

1. **`db.BeginTx()` 拿不到 MVCC 并发写。** binding 的 `BeginTx` 硬编码 `ExecContext(ctx, "BEGIN", nil)`，
   且形参是 `_ driver.TxOptions`（**TxOptions 被完全忽略**）。`BEGIN` 对应 `TransactionMode::Write`，
   在 MVCC 下走 `begin_exclusive_tx_with_checkpoint_read_guard`（`core/vdbe/execute.rs`）——**写者互斥**，
   并发写会报 `database is busy: database is locked`。而 `BEGIN CONCURRENT`（Turso 扩展，SQLite 没有）
   对应 `TransactionMode::Concurrent` → `mv_store.begin_tx`，才是多版本并发写。
2. **冲突语义**：同一条记录被并发写 → 立即 `Write-write conflict`（first-committer-wins），不等待；
   中止的是**事务**不是**连接**；冲突后连接会静默回到 autocommit。正确姿势是「重试整个事务」。
   本仓库封装了 `examples/go-sdk/mvccx`（`Begin` / `Run` + 自动重试 + `done` 保护）。
   重试语义上等价于「只跑成功的那一次」——中止会**整体回滚**（实测连事务内新插入的行也不留），
   所以纯 DB 操作不需要额外幂等；需要幂等的是事务体里的**非 DB 副作用**（发邮件/调外部 API/发消息），
   它们不会被回滚，会随重试重复执行（用 outbox 或幂等键解决）。
3. **忙等待是「忙等」不是 sleep（会烧 CPU）**：WAL 下写锁争用时，`driver_db.go` 的 `executeFully`
   对 `TURSO_IO` 状态直接 `continue`，中间不 sleep。实测「单个写者等待被占用的写锁 733ms」消耗
   CPU 729ms ≈ **1 个核**；8 个写者压测能吃 6–7 个核。`busy_timeout` 只把「报错」换成「忙等」，
   不省 CPU。缓解：busy_timeout 别设太大 / 用 MVCC `BEGIN CONCURRENT` / 自建重试要退避 / 写操作串行化。
4. **`PRAGMA journal_mode='mvcc'` 是「库级」设置**（不是按连接、也不是按表）：写进页 1 头偏移 18/19，
   值为 255 = Turso 扩展的 `Version::Mvcc`（`core/storage/sqlite3_ondisk.rs`：1=Legacy / 2=Wal / 255=Mvcc）。
   实测全新进程直接读到 `mvcc`，且对**开启之前**建的表也能 `BEGIN CONCURRENT`。目录里会多出 `.db-log`。
   注意「库的模式」≠「事务类型」：库是 mvcc 后，是否并发写仍由 `BEGIN CONCURRENT` 决定（普通 `BEGIN` 走 exclusive）。
5. **`1 = Legacy` 只是兼容旧 SQLite 库，不是可用运行模式**：它等价于 SQLite 的回滚日志
   （`Version::Legacy => JournalMode::Delete`）。实测 `journal_mode='delete'/'truncate'/'persist'` 一律返回
   `wal`（`supported()` 只认 Wal|Mvcc）；只有打开旧库才会遇到——只读打开会保留 Legacy 并 warn，
   可写打开则**自动转成 WAL**（header `01 01` → `02 02`，数据保留，见 `core/database.rs:2071`）。
6. **CDC 在 MVCC 下是可用的**（v0.8.2 实测）：`docs/agent-guides/mvcc.md` 的 “Current Limitations” 里
   并没有 CDC；COMPAT.md 里「CDC 被拒」那句讲的是 **WITHOUT ROWID 表**，不是 MVCC。实测 MVCC 库里
   `turso_cdc` 正常记录（含 `change_txn_id` 与 COMMIT 记录，`change_type` 2），而且**被写写冲突中止的
   事务不会写进 CDC**（回滚的改动不记录）——多写者并发下语义是对的。注意 CDC 是**按连接**的
   （`capture_data_changes_conn`），要捕获哪条连接的改动就得在那条连接上开。
   ⚠️ 但仓库里 `.claude/skills/cdc/SKILL.md` 写着「CDC and MVCC are mutually exclusive」——那是**过时的**，
   描述的是 0.6 的行为。`core/vdbe/execute.rs:19024` 的注释承认了这段历史（“0.6 rejected it with
   «cannot enable MVCC while CDC is active»; that guard was lost in the logical log v3 redesign”），
   0.8 把限制**恢复并推广**为：**不能在「CDC 处于开启状态」的连接上切换 journal_mode**（任何方向），
   会报 `cannot change journal_mode (from wal to mvcc) while CDC capture is active`。原因是 CDC 是连接级
   状态、吃的是当前 journal mode 的写路径，偷偷换模式会让捕获静默失效却仍显示 on。`core/translate/pragma.rs:600`
   的 CDC 设置分支里已经没有 MVCC 检查。结论：**库是 mvcc 时完全可以开 CDC**（Turso 自己的 sync 引擎就依赖这点）；
   只是别在 CDC 开着时改模式——先定好 journal_mode，再开 CDC。

## 在本沙箱里运行

首次拉依赖需要联网（`go mod tidy`）。之后运行示例时，Go 默认构建缓存 `~/.cache/go-build` 不在可写根里，需重定向：

```bash
cd examples/go-sdk
go mod tidy                       # 首次：需要联网
GOCACHE=/tmp/gocache go run .     # 之后可离线运行
```

## 实测输出（`examples/go-sdk`）

```
== 内存库 :memory: ==
sqlite_version() = 3.50.4
  1	bolt    0.12
  2	nut     0.03
  3	washer  0.01

== 文件库 /tmp/turso-go-.../demo.db ==
提交 1 行、回滚 1 行后，表内行数 = 1（期望 1）
```

即：驱动注册、`:memory:` 与文件库、参数化写入、读取、显式事务提交/回滚均正常。

## TODO

- [ ] 覆盖 `experimental=`、`async=1`、加密选项的实测。
- [ ] 若拿到 Turso Cloud 账号，验证真实的远端 + auth token 路径（本地 `--sync-server` 已验证）。

## RAG / 本地 embedding 的 Go 库选型

`rag` 子命令演示了完整 RAG：**本地 embedding 模型 → 分块 → 存入 Turso 向量 → 最近邻检索 → 组装上下文**。

Go 侧的 embedding 库对比：

| 方案 | 说明 | 评价 |
| --- | --- | --- |
| `github.com/kelindar/search/llama` | 纯 Go，经 [purego](https://github.com/ebitengine/purego) 调 llama.cpp，直接加载 GGUF（如 all-MiniLM-L6-v2，384 维） | **本篇采用**，最省事；要求 go 1.27；需预编译/自编译 `libllama_go.so` |
| `github.com/knights-analytics/hugot` | ONNX + onnxruntime，支持 sentence-transformers | 备选；需 onnxruntime 动态库 + ONNX 模型 + tokenizer |
| `github.com/tmc/langchaingo` | 多 provider 抽象 | 本地推理要 cgo/llama.cpp，或用云端 provider（需 key） |
| `github.com/nlpodyssey/cybertron` | 纯 Go（spaGO） | 需自行把权重转成 spaGO 格式，较重 |
| `github.com/kelindar/search/openai`、langchaingo 的 OpenAI embeddings | 云端 embedding | 需要 API key，本环境无法验证 |

Turso 在这里充当**向量库**：片段向量以 `vector32` blob 存表，检索用 `vector_distance_cos` 排序取 top-k。

**中文 / 多语**：MiniLM-L6-v2 只支持英文，中文要换模型。本仓库中文演示用
**`bge-small-zh-v1.5`**（512 维，BERT 系，GGUF f16 ≈48MB，来自 `CompendiumLabs/bge-small-zh-v1.5-gguf`）；
多语可选 `bge-m3`（1024 维，较大）。语料用古腾堡的《山海經》#25288、《論語》#23839（公有领域），
落在 `examples/go-sdk/data-zh/`；切换方式见 `examples/go-sdk/README.md`。
注意中文没有空格：分块按**字符数**（220 字/块），而不是词数。

已知坑（详见 `examples/go-sdk/README.md`）：官方预编译的 `libllama_go.so` 在部分 CPU 上 `SIGILL`，
用 `scripts/build-llama-lib.sh`（`-DGGML_NATIVE=OFF`）本地编译即可；语料用古腾堡公有领域文本。
