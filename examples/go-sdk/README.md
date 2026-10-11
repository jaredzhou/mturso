# Go SDK 综合示例

演示 **Turso 官方 Go SDK** 的主要功能，全部本地可跑（sync 会起一个本地 sync server）。

## SDK

- 模块：`turso.tech/database/tursogo`（随引擎仓库 `github.com/tursodatabase/turso` 的 `bindings/go` 发布，版本与引擎同步，如 v0.8.2）。
- 驱动名：`turso`（标准 `database/sql` 接口）。
- 无 CGO：用 [purego](https://github.com/ebitengine/purego) 调 Rust 的 C ABI；预编译原生库来自 `github.com/tursodatabase/turso-go-platform-libs`。
- 旧的独立仓库 `github.com/tursodatabase/turso-go`（v0.2.x，内置 `libs/`、带 GORM）已被上面的取代。

## 运行

```bash
go mod tidy                       # 首次：需要联网（拉 purego + 预编译原生库）
GOCACHE=/tmp/gocache go run . all # 跑 basic/cdc/vector/concurrent/mvcc

GOCACHE=/tmp/gocache go run . basic
GOCACHE=/tmp/gocache go run . cdc
GOCACHE=/tmp/gocache go run . vector
GOCACHE=/tmp/gocache go run . concurrent
GOCACHE=/tmp/gocache go run . mvcc

# sync 需要监听本地端口，需在有网络权限的环境运行（沙箱内请提权）
GOCACHE=/tmp/gocache go run . sync

# rag 需要先准备模型与语料（见下），并让动态库可被找到
bash ../../scripts/fetch-rag-assets.sh    # 下载 MiniLM GGUF（25MB）
bash ../../scripts/fetch-rag-corpus.sh    # 抓取真实文章（古腾堡，公有领域）
bash ../../scripts/build-llama-lib.sh     # 若预编译库在当前 CPU 上崩溃，则本地编译
LD_LIBRARY_PATH=$PWD/../../.cache/rag TURSO_RAG_ASSETS=$PWD/../../.cache/rag GOCACHE=/tmp/gocache go run . rag
```

`GOCACHE` 重定向是因为沙箱里 `~/.cache/go-build` 不可写；在有权限的环境下可以省略。

> 依赖要求 **Go 1.27+**（`github.com/kelindar/search/llama` 要求 go 1.27）；本机已用
> `go env -w GOTOOLCHAIN=go1.27.1` 升级。

`go run .` 可直接用；若执行 `go build ./...` 报 `error obtaining VCS status`，
是本仓库的 `.git` 为空目录（不是有效仓库）导致，加 `-buildvcs=false` 即可。

## 各命令演示什么

| 命令 | 覆盖的 SDK / SQL 能力 |
| --- | --- |
| `basic` | `sql.Open("turso", ...)`、`:memory:` 与文件库、`Prepare` + 参数绑定、`Query`/`Scan`、`Begin`/`Commit`/`Rollback`、`sqlite_version()` |
| `cdc` | 变更数据捕获：`PRAGMA capture_data_changes_conn('full')`，读 `turso_cdc` 表（`change_type` 1=INSERT 0=UPDATE -1=DELETE 2=COMMIT）。MVCC 库下同样可用，详见下节 |
| `vector` | 向量检索：`vector32()` 构造、`vector_distance_cos/l2/dot`，按距离做最近邻 top-k |
| `concurrent` | 并发写（WAL）：8 个连接并行写，并**实测**「单写者 + 忙等待排队」的真相（含单连接基线与关闭忙等待的对照） |
| `mvcc` | MVCC：`PRAGMA journal_mode='mvcc'` + `BEGIN CONCURRENT`，写事务**真正并行**（与 WAL 对照） |
| `conflict` | MVCC 写写冲突：改同一条记录时**立即报错而非等待**，并演示事务被中止后的坑 |
| `retry` | MVCC 重试预算实测：争用强度 / 退避策略 → 所需尝试次数（回答「重试几次合适」） |

## 并发写：为什么「默认模式下不允许并发写」，示例却全部成功？

WAL 模式下确实是**单写者**（`docs/agent-guides/transaction-correctness.md`：one writer at a time），
但驱动有个 **busy timeout（默认 5000ms，可用 `_busy_timeout=` 调）**：抢不到写锁的写者会**排队等待**，
而不是立刻失败。所以「全部成功」度量的是**可靠性**，不是**并发度**。

`concurrent` 命令用三组对照把这点拆开（实测输出）：

```
A) 8 连接 + busy_timeout=10000ms
   尝试 200 次：成功 200，失败 0；墙钟 1037ms；单连接基线 757ms → 无并行加速
B) 8 连接 + busy_timeout 关闭(-1)（按持续时间压测 500ms）
   成功写入 51 次，尝试 70690 次 → 每成功 1 次要试 ~1386 次
   写锁易主 48 次；8/8 个写者都成功写入过
C) 1 个写者 + busy_timeout 关闭(-1)（对照）
   尝试 25 次：成功 25，失败 0     ← 没有争抢就不会失败
D) 长写事务独占写锁 400ms + busy_timeout=5000ms → 第二个写者等了 435ms 才成功
E) 长写事务独占写锁 + busy_timeout 关闭      → 第二个写者 0s 立即失败（database is locked）
```

要点：

- **A 没有并行加速**（8 连接的墙钟 ≈ 单连接基线），说明 200 次写是被写锁**串行**执行的；`_busy_timeout` 只是把「失败」变成了「排队」。
- **写锁不是「所有权」**：它按事务获取/释放，持有者两次写之间就是空档，别人可以抢走。实测二写者 500ms 内**易主 91 次**，8 写者 73 次，**每个写者都能推进**。所以不存在「谁先抢到就永久独占」。
- **关闭忙等待的真实代价不是「饿死别人」，而是海量无效自旋**：失败的尝试只要 ~48µs，而成功一次要 ~4ms（差约 100 倍），于是每成功 1 次要试上千次（B 组实测 ~1386 次）。`_busy_timeout` 的意义就是把这些空转换成高效等待。
- **C 是对照**：单写者、同样关闭忙等待 → **0 失败**，说明失败来自**争抢**，不是「关闭忙等待」这条设置。
- **D/E** 证明写锁是真的：不给忙等待就立刻 `database is busy`。
- 想要真正的多写者并行，用 **MVCC**（`PRAGMA journal_mode='mvcc'` + `BEGIN CONCURRENT`）：

> ⚠️ **测量陷阱（我们踩过）**：如果用「固定尝试次数」来压测，失败者会在 ~1ms 内把配额烧光然后退出（因为失败只要 ~48µs），结果看起来像「赢家永久独占、锁从不易主」——那是**测量偏差**，不是事实。评估锁竞争必须按**持续时间**压测。

### 自旋的代价：会吃满 CPU，但不会死锁

实测（12 核机器，8 个写者各压 1.5s，CPU 用 `getrusage` 统计）：

| 场景 | 墙钟 | CPU 时间 | 占用核数 | 成功/尝试 |
| --- | --- | --- | --- | --- |
| 关闭忙等待 + 客户端自旋重试 | 1.51s | 10.1s | **6.7 核** | 183 / 212054 |
| `busy_timeout=5000ms` | 1.95s | 12.0s | **6.2 核** | 352 / 352 |

单独测「一个写者等待被占用的写锁」（`busy_timeout=5000`，单次 insert）：

```
等待 733ms，期间消耗 CPU 729ms → 0.99 个核   ← 是忙等自旋，不是 sleep
```

根因在 **Go 驱动**：`driver_db.go` 的 `executeFully` 遇到 `TURSO_IO` 状态时直接 `continue`（马上再调 `turso_statement_run_io`），**中间没有 sleep**：

```go
case TURSO_IO:
    if err := turso_statement_run_io(stmt); err != nil { return 0, err }
    continue          // ← 紧循环，忙等
```

原生侧其实有一套指数退避的等待计划（`core/busy.rs` 的 `DELAYS`：1/2/5/10/…/100ms），但通过这个绑定走的是忙轮询路径。

所以结论是：

- **不会死锁、不会饿死**：锁从不被等待者持有。实测 8 个写者互相易主几十次、心跳 goroutine 最大间隔稳定在 5–10ms、进程始终响应。
- **但会烧 CPU**：每个等待者约 1 个核，8 个写者能吃掉 6–7 个核。`busy_timeout` 只是把「报错」换成「忙等」，**并不省 CPU**。
- 缓解：① `busy_timeout` 别设太大；② 需要并发写就用 MVCC `BEGIN CONCURRENT`（冲突即时返回，不排队）；③ 自己的重试循环务必修退避；④ 或者干脆把写操作串行化（单写者）。

```
### mvcc
  8 个写事务：提交 8，失败 0；同时进行的写事务最多 = 8 个
  MVCC 对照：holder 持写事务 400ms 期间，第二个写事务用时 13ms → 真正并行
```

## MVCC 的写写冲突：为什么「立即报错」而不是等待？

### `PRAGMA journal_mode='mvcc'` 的作用域：按 **库**，不按连接、也不按表

- 它是**数据库级**设置，会写进数据库文件头（页 1、偏移 18/19）。源码 `core/storage/sqlite3_ondisk.rs` 里只有三个取值：`1 = Legacy`、`2 = Wal`、**`255 = Mvcc`**（Turso 自己的扩展，标准 SQLite 只认前两个）。实测：WAL 库头部是 `02 02`，MVCC 库是 `ff ff`。
- **持久化、跨进程生效**：进程 A 执行 `PRAGMA journal_mode='mvcc'` 后退出，一个**全新进程** B 直接读同一个库，`PRAGMA journal_mode` 返回 `mvcc`。目录里会多出 `.db-log`（MVCC 逻辑日志）。
- **不是按表**：表不携带 journal mode。实测在开启 mvcc **之前**建的表并写入数据，之后开启 mvcc，新进程里照样能对它用 `BEGIN CONCURRENT`。所以不存在「只有那个连接建的表才走 MVCC」。
- **后续连接自动继承**，不需要再发 pragma。
- 但别把「库的模式」和「单个事务的类型」混为一谈：库处于 mvcc 之后，一个事务是否允许并发写，仍取决于它用的是 `BEGIN CONCURRENT` 还是普通 `BEGIN`（后者走 exclusive 路径，会 `database is busy`）。
- 它还是个可切换的开关：实测把库切回 `PRAGMA journal_mode='wal'`，文件头从 `ff ff` 变回 `02 02`，数据保留。

### 附：header 版本里的 `1 = Legacy` 是什么

`Legacy` 指 SQLite 的**回滚日志（rollback journal）**模式，也就是 `journal_mode=delete` 那一族（源码 `core/storage/journal_mode.rs`：`Version::Legacy => JournalMode::Delete`）。它和 WAL 的经典区别：

| | Legacy（rollback journal） | WAL |
| --- | --- | --- |
| 日志文件 | `<db>-journal` | `<db>-wal` |
| 提交方式 | 写前把**原始页**备份进 journal，提交后删掉；崩溃时用它回滚 | 追加新的页帧，提交帧一到即算提交；主库之后由 checkpoint 合并 |
| 读写并发 | **读写互斥**：写者需独占锁，读者会挡住写者 | 读不阻塞写、写不阻塞读（仍单写者） |
| 恢复 | 用 journal 回滚半写完的页 | 重放/丢弃 WAL 里的未提交帧 |

但在 Turso 里 **Legacy 不是一种可用的运行模式，只是「读旧 SQLite 库」的兼容路径**：

- `PRAGMA journal_mode='delete' / 'truncate' / 'persist'` 实测**一律返回 `wal`**（连非法值也返回 `wal`）；`JournalMode::supported()` 只认 `Wal | Mvcc`，`as_version()` 也只给这两个返回 header 值。所以你没法用 Turso 造出 legacy 库。
- 只有打开「别人造的旧库」时才会遇到。实测（手工把 header 改成 `01 01`）：
  - **只读**打开 → 打印 `Running in Legacy mode.`，能正常读数据，header 不变；
  - **可写**打开 → Turso **自动转成 WAL**（header `01 01` → `02 02`，生成 `-wal`），数据完好（源码 `core/database.rs:2071`）。

`conflict` 命令复现（实测）：

```
场景1：A 持有 id=1 未提交；B 写同一行
  A update id=1        -> ok
  B update id=1(同一行) -> turso: error: Write-write conflict     ← 立即返回，不等待
  B update id=2(另一行) -> ok                                     ← 行级检测：改别的行没事
  B COMMIT             -> cannot commit - no transaction is active
最终值: t[1]=1 t[2]=42

场景2：B 先写 id=2（不冲突），再写 id=1（冲突）
  最终值: t[1]=1 t[2]=0    ← 冲突中止的是整个事务，先前的写一起回滚

场景3：A 已提交，但 B 的快照更早，再写同一行
  B update id=1 -> turso: error: Write-write conflict            ← first-committer-wins

场景4：同一个连接重试
  B update id=1(冲突) -> Write-write conflict
  B 同连接 BEGIN CONCURRENT -> ok；update -> ok；COMMIT -> ok   ← 连接可复用，事务不可复用

场景5：同一个连接，但重试时「忘了 BEGIN」（客户端没做失败处理）
  重试① 无 BEGIN -> ok（已在 autocommit 下提交）；重试② 失败 -> 半截写入

场景6：正确的失败处理（冲突即重试整个事务）
  2 个并发写者 × 20 次自增：最终 v = 40（期望 40），重试 24 次，失败 0 次
```

**根本原因：这不是锁，没有什么可以等。**

- WAL 争的是**锁**：持有者释放后，等待者的工作依然成立，所以等待是有意义的（这正是 `_busy_timeout` 干的事）。
- MVCC 下事务已经**读了快照、并基于快照算好了要写什么**。若另一事务改过同一行，这个前提就已经被破坏；**即使等到对方结束再写，也会丢掉对方的更新（lost update）或破坏快照隔离**。所以正确的处理只有两条路：**中止**，或**重新读 + 重算（由应用重试）**。Turso 选了前者。
- 源码依据：`core/mvcc/mod.rs` 模块文档明确写 *"prevents lost updates by detecting the write-write conflict and letting the first-writer win by aborting the later transaction"*；`core/mvcc/database/mod.rs` 的 `check_version_conflicts` 在 `end_ts > tx.begin_ts`（或对方事务处于 `Preparing`）时返回 `LimboError::WriteWriteConflict`。
- 这是典型的**乐观并发控制（first-committer-wins）**：代价是应用要负责重试，收益是**不阻塞、不可能死锁**（等待式方案下「两个事务各持一行再互等」就是死锁），且冲突粒度是**行级**而非 WAL 的库级写锁——所以改不同的行可以真正并行。

实践注意：

- 冲突中止的是**事务**，不是**连接**：同一个连接重新 `BEGIN CONCURRENT` 就能重试成功（场景4）。连接完全可以复用，这一点不用担心。
- 唯一要小心的是**失败处理要写对**：冲突后连接会静默回到 autocommit。如果重试代码忘了重新开事务，语句会各自提交 → 中途失败就留下半截数据（场景5）。那是**客户端代码**的问题，不是数据库的限制。
- `_busy_timeout` 对写写冲突**无效**（它不是锁等待），只有重试有用。
- 正确姿势（场景6）：把整个事务体包进重试循环 —— 捕获可重试错误（`Write-write conflict` / `busy`）→ `ROLLBACK` 收尾 → 重新 `BEGIN CONCURRENT` 重跑，同一连接即可，配一点退避。示例代码：`withMVCCRetry`。
- 还有一个容易踩的点：`database/sql` 的 `db.BeginTx` 发的是**普通 `BEGIN`**，在 Turso 下**拿不到 MVCC 并发写语义**（会退化成写锁，报 `database is busy`）。要 MVCC 必须自己在固定的 `*sql.Conn` 上发 `BEGIN CONCURRENT`。

## 能不能把 `BEGIN CONCURRENT` 抽象成 `Begin`？

能。先看为什么 binding 没帮你做（`turso.tech/database/tursogo@v0.8.2` 的 `driver_db.go`）：

```go
func (c *tursoDbConnection) BeginTx(ctx context.Context, _ driver.TxOptions) (driver.Tx, error) {
	...
	_, err := c.ExecContext(ctx, "BEGIN", nil)   // 硬编码 BEGIN
	...
}
```

- 第二个形参是 `_ driver.TxOptions`：**TxOptions 被直接忽略**，所以 `sql.TxOptions{Isolation: ...}` 传什么都没用；也没有 DSN 选项能改默认事务模式。
- 注意这**不是「不支持事务」**：SQLite 有事务，这里的 `BEGIN` 就是标准事务（`TransactionMode::Write`）。只是它在 MVCC 下走 `begin_exclusive_tx_with_checkpoint_read_guard`（源码 `core/vdbe/execute.rs`），**写者互斥**——所以并发写会报 `database is busy`。
- 而 `BEGIN CONCURRENT` 是 **Turso 特有的扩展**（SQLite 没有），对应 `TransactionMode::Concurrent` → `mv_store.begin_tx`，多版本、允许并发写者。

结论：`BeginConcurrent` 得自己封装。本仓库给了一个 `examples/go-sdk/mvccx`：

```go
tx, err := mvccx.Begin(ctx, conn)        // 发 BEGIN CONCURRENT，用法像 sql.Tx
_, err = tx.ExecContext(ctx, `update t set v = v + 1 where id = 1`)
err = tx.Commit()

// 或者直接用带自动重试的 Run（推荐）：
err = mvccx.Run(ctx, conn, mvccx.Options{Attempts: 50}, func(ctx context.Context, tx *mvccx.Tx) error {
	_, err := tx.ExecContext(ctx, `update t set v = v + 1 where id = 1`)
	return err
})
```

`mvccx.Tx` 带 `done` 保护：事务被冲突中止后再操作会返回 `ErrTxDone`，正好堵住场景5那个「静默 autocommit」的坑。

> 更彻底的做法是包一层 `driver.Connector`，拦截 `BeginTx` 让它直接发 `BEGIN CONCURRENT`，这样连 `db.BeginTx()` 都能用；但需要自己实现 `driver.Tx` 并委托连接（`tursoDbTx` 未导出）。这算是上游值得改进的点：让 `BeginTx` 尊重 `TxOptions`（例如把 `Isolation: sql.LevelSnapshot` 映射到 concurrent），或提供一个 DSN 参数。

## MVCC 重试多少次合适？

`go run . retry` 可复现。场景是最坏情况：所有写者抢**同一行**做 `v = v + 1`，每个写者 10 个逻辑事务，尝试上限 200。

**① 争用强度 → 所需尝试次数（无退避，即惊群式立即重试）**

| 写者数 | 平均尝试 | p99 | 失败 |
| --- | --- | --- | --- |
| 1 | 1.00 | 1 | 0 |
| 2 | ~27 | 56 | 0 |
| 4 | ~71 | 200 | 1 |
| 8 | ~95 | 200 | 11 |
| 16 | ~119 | 200 | 53 |

**② 8 个写者时，退避策略的影响**

| 退避 | 平均尝试 | p99 | 失败 |
| --- | --- | --- | --- |
| 无退避 | ~94 | 200 | 13 |
| full jitter 指数 | **~2.6** | 15 | 0 |

结论（`mvccx.Options` 的默认值就是据此定的）：

1. **需要的次数主要由退避策略决定，别拍脑袋定次数。** 无退避是惊群式立即重试，才 2 个写者抢一行平均就要 ~27 次；换成 full jitter 指数退避，8 个写者平均只要 ~2.6 次。
2. **用「次数 + 时间预算」双重约束。** 默认建议 `Attempts=10`、`Budget=200~500ms`、`BaseDelay=1ms`、`MaxDelay=20~50ms`。次数上限防失控，时间预算保尾延迟。
3. **看 p99，不要看平均。** 平均 2.6 次但 p99 15 次——极少数事务会退避到几十毫秒。SLO 不容忍时，收窄 `Budget` 并让上层决定（返回 503 / 重新入队），而不是无限重试。
4. **p99 长期几十次以上 = 结构性热点争用，重试解决不了。** 此时改访问模式：分片计数（把热点行拆成 N 行再求和）、写批量聚合、或单写者队列串行化。
5. **纯数据库操作不需要额外幂等**：MVCC 冲突会**整体回滚**（实测连事务内新插入的行也会被回滚），所以重试等价于「只跑成功的那一次」。**需要幂等的是事务体里的非数据库副作用**——发邮件、调外部 API、发消息这类动作不会被回滚，会随每次重试重复执行（实测：事务体跑了 41 次，副作用也就发生了 41 次）。对策：把副作用挪到**提交之后**（outbox：事务内只写「待发送」记录），或给外部调用带**幂等键**。
6. 别忘了上一节的教训：重试循环**一定要退避**，否则 CPU 会被吃满。
| `sync` | 离线优先同步：自起本地 sync server，演示 bootstrap、`Push`、`Pull`、`Checkpoint`、`Stats`，并用 `/v2/pipeline`（SQL-over-HTTP）核对两端数据 |
| `rag` | RAG：用**本地 embedding 模型**对**真实文章**分块嵌入（英文 MiniLM-L6-v2 / 中文 bge-small-zh-v1.5）→ 存进 Turso 向量 → 最近邻检索 → 组装上下文 |

## RAG 演示（`rag`）

一个最小但完整的 RAG 应用场景：

1. **embedding**：`github.com/kelindar/search/llama` —— 纯 Go 经 [purego](https://github.com/ebitengine/purego) 调 llama.cpp，加载常见模型 **all-MiniLM-L6-v2**（GGUF Q8_0，384 维）。这是 Go 侧最省事的「本地跑真实 embedding」方案（另一个选项是 ONNX + onnxruntime，如 `hugot`）。
2. **语料**：`data/` 下两篇真实文章（古腾堡计划，公有领域）：《联邦党人文集》《福尔摩斯探案集》，各截取约 1200 词。
3. **分块**：`chunkText` 按句子聚合成约 90 词的块（兼容 `\r\n`），得到 ~35 个片段。
4. **向量库**：片段向量以 `vector32` blob 存进 **Turso**，检索直接用 Turso 的 `vector_distance_cos` 做最近邻。
5. **检索 → 增强**：对每个查询做嵌入，取 top-3 片段并拼成给 LLM 的上下文。

实测效果（跨文档路由正确）：

```
查询："Should the people adopt the proposed plan of government?"
  [federalist-papers#02] cos_dist=0.5401  It has been frequently remarked that it seems to have been reserved…
查询："What did Holmes deduce about the King of Bohemia's case?"
  [sherlock-holmes#01] cos_dist=0.5719  To Sherlock Holmes she is always _the_ woman…
```

### 资源准备与已知坑

```bash
bash scripts/fetch-rag-assets.sh   # 下载 MiniLM-L6-v2.Q8_0.gguf（25MB）+ 官方预编译的 libllama_go.so
bash scripts/fetch-rag-corpus.sh   # 抓取并截取古腾堡文本 -> examples/go-sdk/data/*.txt
bash scripts/build-llama-lib.sh    # 备用：本地编译 libllama_go.so
```

- 资源默认落在仓库内 `.cache/rag/`（**不要提交**：模型 25MB + 动态库数 MB）。
- 运行时需要 `LD_LIBRARY_PATH` 指向含 `libllama_go.so` 的目录（该库靠 `LD_LIBRARY_PATH`/cwd 查找）。
- **坑**：官方预编译的 `libllama_go.so` 在部分 CPU 上会 `illegal instruction (SIGILL)`（编译时用了本机不支持的指令）。此时用 `scripts/build-llama-lib.sh` 本地编译（`-DGGML_NATIVE=OFF`）即可。

### 中文语料

英文模型（MiniLM-L6-v2）对中文效果差，中文请换成 **bge-small-zh-v1.5**（512 维，BERT 系，f16 约 48MB，同样由 `fetch-rag-assets.sh` 下载）：

```bash
bash scripts/fetch-rag-corpus-zh.sh    # 抓中文语料 -> examples/go-sdk/data-zh/（山海经、论语，公有领域）
cd examples/go-sdk
LD_LIBRARY_PATH=$PWD/../../.cache/rag \
TURSO_RAG_ASSETS=$PWD/../../.cache/rag \
TURSO_RAG_MODEL=$PWD/../../.cache/rag/bge-small-zh-v1.5-f16.gguf \
TURSO_RAG_DATA=data-zh \
GOCACHE=/tmp/gocache go run . rag
```

实测（跨文档路由同样正确）：

```
模型：bge-small-zh-v1.5-f16.gguf
语料：28 个片段（来自 2 个文件），embedding 维度 = 512，块上限 = 220 字符

查询：精衛填海講的是什麼故事？
  [shanhaijing#07] cos_dist=0.5224  有獸焉，其狀如羊而無口…
查询：孔子怎樣談論學習與仁德？
  [lunyu#13] cos_dist=0.3280  子曰：「不仁者，不可以久處約…」
查询：書中記載了哪些上古山川與神獸？
  [shanhaijing#05] cos_dist=0.4514  又東三百四十里，曰堯光之山…
```

实现上：中文没有空格，所以分块按**字符数**（220 字/块）而不是词数，句读同时识别 `。！？；`；语料里若有换行引入的空格也会清理掉。

## 实测输出（节选）

```
### basic：driver 基础
  sqlite_version() = 3.50.4
  1	bolt    0.12
  ...
  文件库 basic.db：提交 1 行、回滚 1 行后 count = 1（期望 1）

### cdc：变更数据捕获
    change_id=1  type=1 (INSERT) table=sqlite_schema id=6
    change_id=3  type=1 (INSERT) table=account  id=1
    change_id=5  type=0 (UPDATE) table=account  id=1
    change_id=7  type=-1(DELETE) table=account  id=1

### vector：向量检索
  查询 [1.0, 0.05, 0.0] 的 top-3（cosine 距离，越小越近）：
    #1 猫    dist=0.0012
    #2 狗    dist=0.0199

### concurrent：WAL 是单写者，「并发写」其实是在排队
  A) 8 连接 + busy_timeout=10000ms
    尝试 200 次：成功 200，失败 0；单连接基线 757ms → 没有并行加速
  B) 8 连接 + busy_timeout 关闭(-1)（持续 500ms 压测）
    成功 51 次，尝试 70690 次（每成功 1 次要试 ~1386 次）；易主 48 次，8/8 个写者都成功过
  C) 1 个写者 + busy_timeout 关闭(-1) → 尝试 25 次：成功 25，失败 0

### mvcc：BEGIN CONCURRENT，写事务才真正并行
  journal_mode = mvcc
  8 个写事务：提交 8，失败 0；同时进行的写事务最多 = 8 个
  MVCC 对照：holder 持写事务 400ms 期间，第二个写事务用时 13ms

### sync：本地 sync server + push/pull/checkpoint/stats
  本地 sync server: http://127.0.0.1:44539
  本地写 2 行并 Push 后，远端 notes 行数 = 2
  远端写 1 行并 Pull（changed=true）后，本地行数 = 3（期望 3）
  Stats: revision="5"
  Checkpoint: MainWalSize 98904 -> 0, RevertWalSize 0 -> 8272
```

## 关于 sync 的本地服务器

- `tursodb --sync-server 127.0.0.1:<port>` 就是 Turso 官方的同步服务端实现；Go 客户端把 `RemoteUrl` 指向它即可（`http://`）。
- 上游 Go 测试用环境变量 `LOCAL_SYNC_SERVER` 指向 `tursodb` 二进制来起这个服务；本示例在自己的进程里 `exec` 起服务并等待就绪。
- 服务端启动时可能打印一条 `no such table: turso_sync_last_change_id` 的 ERROR —— 它不是故障，是**首次同步**的预期结果，详见下节。

### 关于 `no such table: turso_sync_last_change_id`

```
ERROR tursodb::sync_server: 473: Batch step 0 failed: Parse error: no such table: turso_sync_last_change_id
```

- 同步引擎会在**被同步的数据库**里维护一张内部状态表 `turso_sync_last_change_id(client_id, pull_gen, change_id)`，记录每个客户端拉到哪个位置（`sync/engine/src/database_sync_operations.rs` 里的 `TURSO_SYNC_TABLE_NAME` / `TURSO_SYNC_CREATE_TABLE`）。
- 客户端第一次同步时，会先发一个 batch 去**读**这张表。此时表还不存在 → 服务端的 batch 执行器把这一步记为失败并打 ERROR（`cli/sync_server.rs` 的 `error!("Batch step {} failed: ...")`），然后把 per-step 错误原样返回。客户端把它理解为「没有历史状态」→ 从 0 开始 bootstrap，随后再用 `CREATE TABLE IF NOT EXISTS` 建表（`ensure_sync_last_change_id_table`）。
- **实测：同一个服务端、连续做 3 次同步，这条报错只出现 1 次**（就是第一次），三次 Push/Pull 全部正常。
- **为什么本示例每次运行都能看到**：示例启动的 sync server 没给 `DATABASE` 参数，默认是 `:memory:`（见 `tursodb --help` 里的 `[default: :memory:]`），所以每次运行都是全新的库 → 每次都是「首次同步」。这也正是它不会在目录里留下 `.db` 文件的原因。
- **想让它不再出现**：给服务端一个持久库，例如 `tursodb --sync-server 127.0.0.1:8080 --sync-dir <dir>`，或指定一个 DATABASE 文件；这样只有第一次会打印。
- **唯一需要警觉的情况**：对**同一个持久化数据库 + 同一个客户端**每次都报这行，说明状态没落盘——那才是真问题。
- 顺带一提：这是「预期情况却记成 ERROR」的日志级别问题，算是上游可以顺手改的小点（首次读不到表本可以记 DEBUG/INFO）。

## 公开 API 全貌（`go doc turso.tech/database/tursogo`）

底层 `turso_*` 绑定函数是**未导出**的，外部能用到的公开入口是这些：

- **driver**：`sql.Open("turso", dsn)`；`NewConnector(dsn, opts...)`、`WithBusyTimeout(ms)`、`ConnectorOption`、`TursoConnector`；`DefaultBusyTimeout`。
- **全局**：`InitLibrary(strategy)`（一般自动完成）、`Setup(TursoConfig)`（日志级别）。
- **同步**：`NewTursoSyncDb`、`TursoSyncDbConfig`（含 `BootstrapIfEmpty`、`LongPollTimeoutMs`、`BusyTimeout`、`Namespace`、`ClientName`、`PartialSync`）、`TursoPartialSyncConfig`、`TursoSyncDbStats`；方法 `Connect / Pull / Push / Stats / Checkpoint`。
- **导出的底层类型/常量**（给需要直接调 C ABI 或自定义 IO 的场景）：`TursoDatabase`、`TursoConnection`、`TursoStatement`、`TursoDatabaseConfig`、`TursoDatabaseEncryptionOpts`、`TursoConfig`、`TursoLog`、`TursoTracingLevel`、`TursoType`、`TursoStatusCode`、`TursoSyncDatabaseConfig`、`TursoSyncStats`、`TursoSyncIo*`、`TursoSyncChanges`、`TursoSyncOperation`、`SQLiteTimestampFormats`。

DSN 选项（`driver_db.go: parseDSN`）：`experimental=`、`async=0|1`、`vfs=`、`encryption_cipher=`、`encryption_hexkey=`、`_busy_timeout=`。
