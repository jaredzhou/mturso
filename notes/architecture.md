# Turso 引擎实现速览

> 本文最初基于对本地 `tursodb` **0.8.2** 二进制的字符串/符号提取（安装凭据
> `~/.config/turso_cli/turso_cli-receipt.json` 显示它来自官方 `tursodatabase/turso` 的 `turso_cli` release）；
> 现在**已用真实源码（tag v0.8.2）核对**。更深的走读见 [`source-walkthrough.md`](./source-walkthrough.md)，
> 本地源码副本在 `/tmp/turso-src`（`scripts/fetch-source.sh` 可重拉）。标注「实测」的是真跑过的。

## 总体定位

- **Turso = SQLite 的 Rust 重写**。二进制内可见构建路径 `.../work/turso/turso/core/...`，即上游仓库名为 `turso`。
- 内部 crate 名仍保留早期代号：核心引擎 crate 为 **`turso_core`**，同步为 **`turso_sync_engine`**，补全机制为 **`limbo_completion`**，CLI 二进制 crate 为 **`tursodb`**。
- 与 SQLite **兼容**：沿用 `sqlite_schema` / `sqlite_sequence` / `sqlite_stat1` 等系统表、`PRAGMA` 家族、VDBE 风格字节码（shell 有 `.opcodes`）；`sqlite_version()` 报 `3.50.4`（**实测**）。
- 在 SQLite 之上**叠加**了向量检索、FTS、MVCC、物化视图、自定义类型、加密、同步、MCP 等。

## 模块地图（来自二进制证据）

### 引擎核心 `core/`

- 入口与句柄：`lib.rs`、`database.rs`、`connection.rs`、`statement.rs`、`executor.rs`、`parameters.rs`
- 目录/schema：`schema.rs`、`pragma.rs`、`entry.rs`、`dbpage.rs`、`btree_dump.rs`、`stats.rs`
- 值系统：`types.rs`、`numeric/{mod,decimal}.rs`、`json_utils.rs`、`percentile.rs`、`series.rs`
- **编译管线**（SQL → 计划）：`translate/` 下按语句类型分文件 —— `select.rs`、`update.rs`、`upsert.rs`、`trigger.rs`、`trigger_exec.rs`、`view.rs`、`window.rs`、`compound_select.rs`、`recursive_cte.rs`、`subquery.rs`、`sequence.rs`、`collate.rs`、`analyze.rs`、`schema.rs`、`result_row.rs`、`values.rs`
- **执行**：`vdbe/mod.rs`（字节码执行）、`searcher.rs`、`function.rs`、`functions/{datetime,math,printf}.rs`

**管线（已由源码确认）**：SQL 文本 → 解析（`turso_parser`，见 `sqlite/parser`）→ `core/translate/`（planner / optimizer / emitter 生成计划与字节码）→ `core/vdbe/` 执行。与 SQLite 的 parse → plan → bytecode → VM 结构一致；`core/vdbe/mod.rs` 自称「执行 I/O 的字节码把控制权交还调用方而不阻塞」，这是与 SQLite 的关键差异。

### 存储 `core/storage/`

- 页与 B 树：`sqlite3_ondisk.rs`（页 1 头、cell、溢出页、record 编解码）、`page_transform.rs`（cell 操作）
- 缓冲：`buffer_pool.rs`（arena 分配）、`page_cache.rs`（CLOCK 淘汰）
- 日志：`wal.rs`（WAL 头、校验和、checkpoint）、`subjournal.rs`（savepoint 子日志）、`journal_mode.rs`
- 数据库/加密：`database.rs`、`encryption.rs`（静态页加密，自定义 “Turso” header magic，多种 cipher）
- 多进程：`shared_wal_coordination.rs` + `slot_bitmap.rs`（`-tshm` 共享 WAL 协调文件），对应 `--experimental-multiprocess-wal`

### 并发控制 `core/mvcc/`

- `cursor.rs`、`database/mod.rs`、`database/checkpoint_state_machine.rs`、`database/group_commit.rs`
- 持久化：`persistent_storage/logical_log.rs`（+ `serializer.rs`）、`portable_logical.rs`

**要点（符号/字符串支持）**：MVCC 采用**行版本 + 时间戳**（`TIMESTAMP_MASK`、62-bit tx/ts 范围）；事务状态 `Active/Preparing/Terminated/Committed`；写路径经 `logical log`（protobuf、CRC、分块/可加密、group commit）持久化，再由 checkpoint 状态机把 MVCC 数据回写进 B 树。MVCC 表 ID 为负数。passive checkpoint 需 `--experimental-mvcc-passive-checkpoint`。

### I/O `core/io/`

- 异步补全模型：`completions.rs`（completion / completion group）、`mod.rs`
- VFS：`io_uring.rs`、`unix.rs`（syscall）、`memory.rs`；另有 `clock.rs`
- 二进制内可见 `liblimbo_regexp`，即扩展以动态库方式 `.load`（`ext/dynamic.rs`、`ext/vtab_xconnect.rs`）

### 索引与扩展

- **FTS**：`index_method/fts/{mod,format,directory,rows}.rs` —— 依赖 **tantivy 0.26.2**（二进制内可见 tantivy 符号与段/schema 逻辑），作为一种 index method 实现（分段写入、merge/optimize）。
- **向量索引**：`index_method/toy_vector_sparse_ivf.rs` —— 稀疏向量 IVF 倒排索引 + 统计表。
- **向量类型/算子**：`vector/vector_types.rs`、`vector/operations/{convert,distance_cos,distance_dot,distance_l2,jaccard,text}.rs`。支持 f32/f64/f8/f1bit 稠密与稀疏向量；距离函数 `vector_distance_cos/dot/l2/jaccard`，构造函数 `vector32/vector64/vector8/vector1bit/vector32_sparse`（**实测**：`vector_distance_cos` 可跑通）。
- **JSON**：`json/{jsonb,path,cache,vtab,mod}.rs` —— JSONB 二进制存储 + JSON path + 虚拟表（**实测**：`json_extract` 可跑通）。
- **物化视图**：`incremental/{view,compiler,dbsp,expr_compiler,operator,filter_operator,project_operator,join_operator,merge_operator,aggregate_operator,input_operator,persistence}.rs` —— **增量（DBSP 风格数据流算子）**实现，底层是 `(operator_id, zset_id, element_id, value, weight)` 的 zset 存储。需 `--experimental-views`。
- **方言**：`dialect/sqlite.rs`（可插拔方言）。

### CLI `cli/`

- `main.rs`、`app.rs`、`input.rs`、`helper.rs`、`dot_command.rs`、`manual.rs`
- `mcp_server.rs`（内置 MCP server，`--mcp`）、`sync_server.rs`（`--sync-server` / `--sync-dir`）
- `commands/{args,import}.rs`、`config/{mod,palette,terminal}.rs`

## 同步（sync）

- 独立 crate **`turso_sync_engine`**，protobuf 协议：`PushUpdatesReqProto` / `PullUpdatesReqProto`，字段含 `server_revision` / `client_revision` / `long_poll_timeout_ms` / pages & query selectors / `stream_kind`（**长轮询**式增量同步）。
- 本地由 `tursodb --sync-server <addr>` 或 `--sync-dir <path>`（按 `/db/{name}` 提供多库）提供服务。

## 特性开关（`--experimental-*`，来自 `--help`）

`--experimental-views`、`--experimental-custom-types`（CREATE TYPE / DROP TYPE / DOMAIN）、`--experimental-encryption`、`--experimental-index-method`、`--experimental-autovacuum`、`--experimental-vacuum`、`--experimental-attach`、`--experimental-generated-columns`、`--experimental-without-rowid`、`--experimental-multiprocess-wal`、`--experimental-mvcc-passive-checkpoint`、`--unsafe-testing`。

## 待办

- [x] clone 源码并逐一对齐（tag v0.8.2）——见 [`source-walkthrough.md`](./source-walkthrough.md)。
- [ ] 用 `.opcodes` 命令辅助，给 VDBE opcode 与 `translate/*` 各文件补一页笔记。
- [ ] 深挖 MVCC 的 logical log 格式（`.db-log`）与 checkpoint 状态机。
