# Turso 源码走读（tag v0.8.2）

> 本文基于**真实源码**：`github.com/tursodatabase/turso`，tag `v0.8.2`（与本地 `tursodb 0.8.2` 对齐）。
> 本地副本在 `/tmp/turso-src`（可用 `scripts/fetch-source.sh` 重新拉取）。文中路径均相对仓库根目录。
> 结论优先引用代码里的 `//!` 模块文档与关键类型定义；未引用的是归纳。

## 一句话架构

Turso 是**进程内（in-process）的 SQL 数据库**，用 Rust 写的 SQLite 重写；但它同时**是一台虚拟机**：
像 SQLite 一样把 SQL 编译成 VDBE 字节码再执行。这个设计让它能承载**多种 SQL 方言**——SQLite 是第一个也是
主要的前端，Postgres 已是另一个独立前端（自带方言与 wire protocol）。官方自述目标是「数据库界的 LLVM：
一个现代可靠的核心，多个前端编译到它上面」。来源：`README.md`。

## 编译与执行管线

1. **解析**：SQL 文本 → AST。方言解析器独立成 crate（`sqlite/parser`，即 `turso_parser`；见 `core/index_method/mod.rs` 的 `use turso_parser::ast`）。
2. **translate（生成字节码）**：`core/translate/mod.rs` 自述为「The VDBE bytecode code generator」，把 AST 翻译成 VDBE 指令序列。
   - 计划结构：`core/translate/plan.rs` 的 `Plan` 枚举 —— `Select` / `CompoundSelect` / `RecursiveCte` / `Delete` / `Update`。
   - 规划与优化：`core/translate/planner.rs`、`core/translate/optimizer/`（`access_method.rs`、`constraints.rs`、`cost.rs`、`cost_params.rs`、`join.rs`、`multi_index.rs`、`order.rs`、`unnest.rs`、`lift_common_subexpressions.rs`，并有设计文档 `OPTIMIZER.md`）。
   - 代码发射：`core/translate/emitter/`（`select.rs`、`delete.rs`、`update.rs`、`gencol.rs`）；表达式翻译在 `core/translate/expr/`（`translator.rs`、`vectors.rs`、`custom_types.rs`、`arrays.rs` …）。
   - 主循环/扫描：`core/translate/main_loop/`（`open.rs`、`seek.rs`、`init.rs`、`body.rs`、`close.rs`、`conditions.rs`、`multi_index.rs`、`in_seek.rs`、`hash.rs`）。
   - 还有 `logical.rs`、`display.rs`、`eqp.rs`（EXPLAIN QUERY PLAN，见 `docs/eqp-json.md`）。
3. **执行**：`core/vdbe/mod.rs` —— 寄存器式 VM，`Program`（`core/vdbe/mod.rs:1864`）持有 `Vec<Insn>`，指令集定义在 `core/vdbe/insn.rs`（`enum Insn`）。执行器在 `core/vdbe/execute.rs`，另有 `builder.rs`、`sorter.rs`、`hash_table.rs`、`bloom_filter.rs`、`rowset.rs`、`vacuum.rs`、`metrics.rs`。

## 核心设计一：异步 I/O = 协作式让出 + 状态机（不用 async/await）

这是 Turso 与 SQLite **最关键的执行模型差异**。来源：`core/vdbe/mod.rs` 与 `docs/agent-guides/async-io-model.md`。

- 「VDBE 的指令集与 SQLite 类似，**但执行 I/O 的字节码会把控制权交还给调用方而不是阻塞**」，因为 Turso 面向 serverless 等高并发场景，异步 I/O 也便于**存储解耦（storage disaggregation）**。
- 类型约定：
  ```rust
  pub enum IOResult<T> { Done(T), IO(IOCompletions) }
  ```
  返回 `IOResult` 的函数必须**反复调用直到 `Done`**。单个 I/O 由 `Completion` 跟踪，多个用 `CompletionGroup` 聚合成一个。
- 所以「执行一条语句」在源码里是一个**可重入的状态机**，而不是一次阻塞调用。`IO` trait（`core/io/mod.rs:424`）有 `yield_now`（`:500`）。I/O 后端：`io_uring.rs`、`unix.rs`（syscall）、`memory.rs`、`memory_yield.rs`、`win_iocp.rs`、`completions.rs`、`vfs.rs`。

## 核心设计二：存储层可插拔（Pager / DatabaseStorage / Wal）

- 存储层主接口是 **`Pager`**（`core/storage/pager.rs:1580`，含 `db_file`、可选 `wal`、`page_cache`、`buffer_pool`、`io`）。来源：`core/storage/mod.rs` 模块文档。
- 两个可插拔 trait：`DatabaseStorage`（`core/storage/database.rs:106`，读写页，「either local or remote」）与 `Wal`（`core/storage/wal.rs:627`）。即页来源和 WAL 都可能是**本地或远端**。
- **SQLite 文件格式**（`core/storage/sqlite3_ondisk.rs` 模块文档）：
  - 文件 = 定长页序列；**第 1 页前 100 字节是 DB 头**（magic `"SQLite format 3\0"`）。
  - 每页 = 页头 + cell 指针数组 + 未分配空间 + cell 内容区；页大小 2 的幂，512–65536 字节，默认 4096（`docs/agent-guides/storage-format.md`）。多字节整数一律**大端**。
  - 页类型标志：`0x02` 内节点索引、`0x05` 内节点表、`0x0a` 叶子索引、`0x0d` 叶子表；另有溢出页、freelist 页。
  - B 树实现：`core/storage/btree.rs`；页变换 `page_transform.rs`；校验 `checksum.rs`；加密 `encryption.rs`（自定义 “Turso” header magic）；savepoint 子日志 `subjournal.rs`。
- **WAL 机制**（`docs/agent-guides/transaction-correctness.md`）：Turso **只用 WAL 模式**；文件为 `.db` + `.db-wal`，**没有 `-shm`**（SQLite 用共享内存做 WAL 索引，Turso 用**进程内**的 `frame_cache` 哈希表 + 原子 read mark，因为不支持多进程）。写：追加帧，COMMIT = 帧头 `db_size` 非零；读：取 read mark（`mxFrame`）看到一致快照。checkpoint 分 PASSIVE/FULL/RESTART/TRUNCATE，默认阈值 1000 页。并发规则：单写者；读写互不阻塞；checkpoint 必须停在活跃 reader 需要的页前。
- 多进程 WAL（实验）：`shared_wal_coordination.rs` + `slot_bitmap.rs`，即 CLI 的 `--experimental-multiprocess-wal`。

## 核心设计三：MVCC（可选 journal mode）

来源：`core/mvcc/mod.rs` 模块文档、`docs/agent-guides/mvcc.md`、`docs/internals/mvcc/{DESIGN,GC,PORTABLE_FORMAT,RECOVERY_SEMANTICS}.md`。

- 通过 **`PRAGMA journal_mode = 'mvcc'`** 启用（**运行时、按库**设置，不是编译开关）。
- 算法实现自论文 **“High-Performance Concurrency Control Mechanisms for Main-Memory Databases”**（Per-Åke Larson et al., VLDB 2011）。防脏写、脏读、不可重复读、丢失更新（写写冲突检测，**first-writer-wins**）。
- 结构（`docs/agent-guides/mvcc.md`）：
  ```
  Database
    └─ mv_store: MvStore
        ├─ rows: SkipMap<RowID, Vec<RowVersion>>
        ├─ txs:  SkipMap<TxID, Transaction>
        ├─ Storage (.db-log 逻辑日志)
        └─ CheckpointStateMachine
  ```
  共享的 `MvStore` 用无锁 `crossbeam_skiplist`；每连接有 `mv_tx`。行版本记录 `begin` / `end` 时间戳与 `btree_resident`（MVCC 启用前就存在的行）。
- 与 WAL 的差异：写粒度是**受影响的行**（WAL 是整页）；持久化到 **`.db-log` 逻辑日志**（WAL 是 `.db-wal`）；隔离级别是**行级快照**。
- 恢复 = 重放事务日志；日志过大则 checkpoint：丢弃「最新事务之后已不可见」的版本并生成快照（`docs/internals/mvcc/DESIGN.md`）。
- 源码：`core/mvcc/{mod,cursor,clock,portable_logical,yield_hooks,yield_points}.rs`、`core/mvcc/database/{mod,checkpoint_state_machine,group_commit}.rs`、`core/mvcc/persistent_storage/{logical_log.rs,logical_log/serializer.rs}`。
- 相关特性：**`BEGIN CONCURRENT`** 用 MVCC 提升写吞吐（`README.md`）。

## 扩展与特性（均在源码中）

- **索引方法（可插拔）** `core/index_method/`：已注册 `backing_btree`、`toy_vector_sparse_ivf`、以及 feature-gated 的 `fts`（`core/index_method/mod.rs`）。FTS 依赖 **tantivy**。
- **向量** `core/vector/`：`vector_types.rs` + `operations/{convert,serialize,distance_cos,distance_dot,distance_l2,jaccard,concat,slice,text}.rs`。
- **JSON** `core/json/`：`jsonb.rs`、`path.rs`、`cache.rs`、`vtab.rs`。
- **增量/物化视图** `core/incremental/`（DBSP 风格算子）与 `core/incremental_blob.rs`。
- **CDC（变更数据捕获）** `core/cdc.rs` + `translate/emitter`：`PRAGMA capture_data_changes_conn`；见 `cli/manuals/cdc.md`。
- **扩展** `extensions/{core,crypto,csv,ipaddr,regexp,fuzzy,completion}`；动态加载看 `core/ext/`。
- **同步（离线优先 / 部分同步）** `sync/engine`（引擎）+ `sync/sdk-kit`（C ABI，头文件 `turso_sync.h`）。CLI 侧 `--sync-server` / `--sync-dir`。
- **Postgres 前端** `postgres/{parser,frontend,server,client,cli,regress,conformance,tests}` + `postgres/COMPAT.md`。
- **多语言绑定** `bindings/{c,dotnet,go,java,javascript,python,react-native,rust,tcl}`，以及底层 C API 桥 `sdk-kit/`（`turso.h`）。
- **CLI** `cli/`：`mcp_server.rs`（MCP）、`sync_server.rs`、`mvcc_repl.rs`、`opcodes_dictionary.rs`、`manuals/`（cdc、custom-types、encryption、index、materialized-views、mcp、vector）。

## 兼容性立场

- 跟踪 **SQLite 3.50.4**：`sqlite_version()` / `sqlite3_libversion()` 都报这个版本，也用它做差分测试（`COMPAT.md`）。
- 「任何未被明确记录为可选扩展的与 SQLite 行为的偏差都被视为 bug」；用差分测试 + SQLite TCL 测试套件验证。

## 给继续研究的人的入口

Turso 官方为 agent/贡献者写了内部指南，值得先读：`docs/agent-guides/`

| 文件 | 内容 |
| --- | --- |
| `async-io-model.md` | `IOResult`、状态机、可重入陷阱、`CompletionGroup` |
| `storage-format.md` | SQLite 文件格式、B 树、页、cell、溢出、freelist |
| `transaction-correctness.md` | WAL 机制、checkpoint、并发规则、恢复 |
| `mvcc.md` | MVCC：快照隔离、版本、限制 |
| `testing.md` / `code-quality.md` / `debugging.md` / `pr-workflow.md` | 工程约定 |

以及 `docs/internals/mvcc/`（MVCC 的 DESIGN / GC / PORTABLE_FORMAT / RECOVERY_SEMANTICS）。

## 待办

- [ ] 逐个走读 `core/vdbe/execute.rs` 与 `core/translate/emitter/select.rs`，把 SELECT 从 AST 到字节码的完整路径画出来。
- [ ] 读 `core/translate/optimizer/OPTIMIZER.md` 与 `cost.rs`，总结代价模型与 join 顺序选择。
- [ ] 对比 `.db-log`（逻辑日志）与 `.db-wal`（物理页日志）的格式细节。
