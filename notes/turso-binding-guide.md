# Turso 绑定开发参考

> 这份笔记有两部分：
>
> - **附一**：`examples/go-sdk/README.md` 的**完整复制**（Go SDK 的实测结论与坑）。
> - **附二**：写给「用别的语言重写 Turso 绑定」的人（当前目标：**MoonBit**）——C API 面、FFI 映射、以及从 Go 绑定踩出来的经验。
> - **附三**：与既有 MoonBit PG 驱动 `jaredzhou/moonpg` 对齐的接口设计——哪些照搬、哪些必须调整、Turso 特有扩展放哪。
>
> 维护方式：附一是原文副本，改行为/结论时请**同时**改 `examples/go-sdk/README.md`，避免两边漂移。

# 附一：Go SDK 综合示例（完整复制自 `examples/go-sdk/README.md`）

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

# 附二：写给绑定作者（C API 与 MoonBit FFI）

> 依据：`sdk-kit/turso.h`（Turso 官方导出的**唯一** C 头，609 行 / ~59 个函数）与 `sdk-kit/README.md`。
> Turso 的官方定位就是「核心用 Rust 实现，通过一个小的、可移植的 C ABI（turso.h）暴露，让别人生成各语言绑定」。

## 1. 需要包的 C API 面

**生命周期**

```
turso_version()
turso_setup(turso_config_t)                        // 进程内全局初始化一次
turso_database_new(config)   -> turso_database_t*
turso_database_open(db)
turso_database_connect(db)   -> turso_connection_t*
turso_database_deinit / turso_connection_deinit / turso_statement_deinit
```

**执行**

```
turso_connection_prepare_single(conn, sql) -> turso_statement_t*     // 单语句
turso_connection_prepare_first(conn, sql)  -> 语句 + 已消耗字节数     // 多语句
turso_statement_bind_positional_{null,int,double,blob,text}(...)
turso_statement_execute(stmt) -> (status, changes)                   // 忽略行
turso_statement_step(stmt)    -> status                              // 逐行
turso_statement_run_io(stmt)                                         // 推进待处理 I/O
turso_statement_reset / turso_statement_finalize
```

**取列 / 取值**

```
turso_statement_column_count / _name / _decltype / _declared_name / _array_dimensions / _base_type / _kind
turso_statement_row_value_kind / _bytes_count / _bytes_ptr / _int / _double
```

**状态码（决定控制流，务必全部处理）**

```
TURSO_OK=0  DONE=1  ROW=2  IO=3  BUSY=4  INTERRUPT=5  BUSY_SNAPSHOT=6
TURSO_ERROR=127  MISUSE=128  CONSTRAINT=129  READONLY=130
TURSO_DATABASE_FULL=131  NOTADB=132  CORRUPT=133  IOERR=134
```

注意 `TURSO_IO` 表示「需要调用方驱动 I/O」——官方 README 明确说这是**可选**的 caller-driven I/O（也支持库驱动）。`TURSO_BUSY_SNAPSHOT` 是 MVCC 冲突的专用状态码，别和 `TURSO_BUSY`（锁忙）混为一谈。

## 2. 三条「照抄 Go 绑定经验」的硬要求

**(a) 别把「忙等」和「需要 I/O」混在一起 —— 否则烧 CPU。**
Go 绑定的 `executeFully`（`driver_db.go:655`）对 `TURSO_IO` 直接 `continue` 且**不 sleep**：

```go
case TURSO_IO:
    if err := turso_statement_run_io(stmt); err != nil { return 0, err }
    continue          // 紧循环
```

对真实 I/O 这是对的（那次调用把 I/O 做完），但对**锁争用/忙等**就退化成自旋：实测「单个写者等待被占用的写锁 733ms」消耗 CPU 729ms ≈ **0.99 个核**；8 个写者压测能吃 **6–7 个核**，而 `busy_timeout` 只把「报错」换成「忙等」，**不省 CPU**。新绑定要么在忙等状态上退避，要么把两种 `IO` 情形区分开。

**(b) 事务类型必须能表达 `BEGIN CONCURRENT`。**
C API 是通用 SQL 接口，`BEGIN CONCURRENT` 只是普通语句。但 Go 的 `database/sql` 集成把 `BeginTx` 硬编码成 `BEGIN`、还**忽略 `driver.TxOptions`**（形参就叫 `_`），导致用户拿不到 MVCC 并发写（普通 `BEGIN` 在 MVCC 下走 exclusive 路径，会 `database is busy`）。
**MoonBit 绑定建议**：提供显式的 `begin_concurrent()`，或让事务选项能映射（例如 isolation=snapshot → `BEGIN CONCURRENT`）。

**(c) 每连接状态必须显式暴露。**
`PRAGMA capture_data_changes_conn`（CDC）、busy timeout 都是**按连接**的；CDC 还额外限制「不能在 CDC 开启时切换 journal_mode」。绑定层要提供 per-connection 的设置入口，不要做成全局开关。

## 3. MoonBit FFI 映射（按 `moonbit-c-binding` 约定）

| C 侧 | MoonBit 建议 |
| --- | --- |
| `turso_database_t*` / `turso_connection_t*` / `turso_statement_t*`（不透明句柄，各有 `*_deinit`） | 优先 **external object + finalizer**（`moonbit_make_external_object`），避免用户漏调 deinit；若想手动管生命周期可用 `#external type` |
| `turso_slice_ref_t`（借用、不转移所有权） | 用 `#borrow` 传 `Bytes` |
| 返回的 C 字符串（`turso_statement_column_name` 等，需 `turso_str_deinit` 释放） | 在 C stub 里 `moonbit_make_bytes` + `memcpy` 拷成 `Bytes`，MoonBit 侧 `@utf8.decode_lossy`；**别忘了释放 C 侧字符串** |
| `turso_status_code_t` | `enum Status { Ok = 0; Done = 1; Row = 2; Io = 3; ... }`（int32），包装层再映射成 MoonBit 错误 |
| 出参（如 changes、行列数） | `Ref[UInt64]` + `#borrow` |
| 回调（`turso_connection_register_scalar_function` / aggregate / collation） | `FuncRef` 或闭包 + trampoline；C 回调期间 GC 可能运行，进出要 `moonbit_incref` / `moonbit_decref` |

工程配置：

```jsonc
// moon.mod.json
{ "preferred-target": "native" }
```

```moonbit
// moon.pkg
options(
  "native-stub": ["stub.c"],
  targets: { "ffi.mbt": ["native"] },
  link(native("cc-link-flags": ["-L/path/to/lib", "-lturso"])),
)
```

字符串方向的细节、所有权标注（`#borrow` / `#owned`）、回调 trampoline 与 AddressSanitizer 验证，都在 `moonbit-c-binding` 技能里，建议动手前先完整读一遍。

## 4. 建议的落地顺序

1. 先确认能链接上（`sdk-kit/README.md` 里有 Rust 侧的最小例子；`turso.h` 可直接给 bindgen 用）。
2. 打通最小闭环：`setup → database_new/open/connect → prepare_single → bind → step/execute → row_value_* → deinit`。
3. 再补多语句（`prepare_first`）、`busy_timeout`、`run_io`、事务（含 `BEGIN CONCURRENT`）。
4. 最后做同步：那是**另一套** C 头 `sync/sdk-kit/turso_sync.h`，与 `bindings/go/driver_sync.go` 对应的用法见附一的「同步」一节。

## 5. 一开始就该写进测试的用例

按附一里的实测结论，这些是最容易踩的：

- 两个连接改**同一行**：断言拿到 `Write-write conflict`（`TURSO_BUSY_SNAPSHOT`），且失败事务**整体回滚**（连它先前的写也不留）。
- 冲突后**同一个连接**重新 `BEGIN CONCURRENT` 重试：断言能成功（连接可复用，事务不可复用）。
- 忘记重新 BEGIN 的重试：断言会写出「半截数据」——这是要防的反面教材。
- MVCC 库里开 CDC：断言 `turso_cdc` 有记录，且**被中止的事务不出现**在 CDC 里。
- CDC 开着时切 `journal_mode`：断言报错。

# 附三：与 `jaredzhou/moonpg` 对齐的接口设计

> 目标：**基础接口与 moonpg 保持一致**（同样的 trait 分层与调用风格），**Turso 特有的能力作为扩展**加进去。
> 依据：moonpg v0.8.11 的 `pkg.generated.mbti`，以及它的 `moonpg.mbt`（trait 定义）/ `conn.mbt` / `pool.mbt` / `tx.mbt` / `values.mbt` / `from_row.mbt` + `pgtype` 子包。

## 0. 好消息：调用风格基本可以原样沿用

- **占位符不用改**：moonpg 用 `$1, $2` 风格。实测 Turso 同时支持 `?`、`?1`、`$1`、`:a`、`@a`、`$a` **六种**写法，所以 `$1` 约定可以**原封不动**保留（无需像某些绑定那样做占位符改写）。
- **`RETURNING` 可用**：实测 `insert ... returning id, name` 正常返回行；`last_insert_rowid()`、`changes()` 也都在。moonpg 里 `query_one("INSERT ... RETURNING id")` 这类写法可以直接用。

## 1. 直接照搬的部分

moonpg 的 trait 分层就是这套设计的骨架，建议一一对应：

| moonpg（`pkg.generated.mbti`） | Turso 绑定 | 对应到的 C API |
| --- | --- | --- |
| `QueryExecutor`（`query` / `query_one` / `execute`，`params? : Array[&ToValue]`） | 同名同签名 | `prepare_single` → `bind_positional_*` → `step`/`execute` |
| `&QueryExecutor::fetch[T : FromRow]` / `fetch_one[T]` | 直接照搬 | 同上 + 行收集 |
| `Rows`（`has_next` / `get_row` / `columns` / `close`） | 照搬 | `turso_statement_step` 的 `TURSO_ROW` / `TURSO_DONE` |
| `Row`（`get[T]` / `get_by_name` / `columns`） | 照搬 | `turso_statement_row_value_*` |
| `ExecResult::affected_rows` | 照搬 | `turso_statement_n_change` |
| `Tx`（`commit` / `rollback`）+ `TxBeginner`（`begin_tx`） | 照搬 | `BEGIN` / `COMMIT` / `ROLLBACK` 语句 |
| `begin_func(beginner, fn(tx){...})` | 照搬，并**加一个带重试的变体**（见 §3.2） | — |
| `Closer` | 照搬 | `turso_connection_close` / `*_deinit` |
| `FromRow` / `FromValue` / `ToValue` / `null` 哨兵 / `params=[...]` 关键字参数 | 照搬 | — |
| `Connection` / `PoolConn` 都 impl `QueryExecutor` + `TxBeginner` + `Closer` | 照搬（池见 §2） | — |

错误类型同构扩展：`TursoError { ConnectionError(String), QueryError(String), NoRows, ... }`，见 §2、§3.1。

## 2. 必须调整的部分（两边模型不同）

| moonpg | 为什么不能照搬 | Turso 版建议 |
| --- | --- | --- |
| `IsolationLevel{ReadCommitted, RepeatableRead, Serializable}` + `TxOptions{isolation_level, read_only, deferrable}` | SQLite/Turso 没有隔离级别；它用 `BEGIN [DEFERRED\|IMMEDIATE\|EXCLUSIVE]` + journal_mode | 换成 `TxMode{Deferred, Immediate, Exclusive, Concurrent}`；`TxOptions{mode?, read_only?, busy_timeout?}` |
| `Format{Text, Binary}` | SQLite 没有 text/binary 传输格式 | 删掉 |
| `Value`（PG 的 Int/Int64/Float/Bool/String/Bytes/Json/Array/Numeric/UUID/Timestamp）+ `pgtype` 的 OID→codec 体系 | Turso 存储层只有 5 种：`Null / Integer / Real / Text / Blob` | `Value` 收缩到 5 个变体；**不需要** OID/codec 映射表（类型扩展另见 §3.5） |
| `Pool`（网络连接池：`min_idle` / `max_idle_sec` / `health_check` / 后台 maintenance） | Turso 是**进程内嵌入式**库，连接本地且廉价 | **保留 API 形状，但换动机**：一个 `Database` 可以 `connect()` **多次**得到多个 `Connection`，每个连接各自持有一个事务——所以「池」在这里是**并发事务数上限**（不是省建连开销）。`max_conns` 是核心旋钮；`min_idle` / `max_idle_sec` / `health_check` / 后台 maintenance 对本地库意义很弱（没有会失效的网络连接），可保留字段但语义降级，或直接裁掉。参考：Go 绑定实际上**每个物理连接开一个独立 database handle**（`Connect` 里 new+open+connect），靠进程内 database registry 按路径共享底层实例——「多连接」这条路是产品实际在用的 |
| `LISTEN / NOTIFY` | Turso 没有通知机制 | 用 **CDC** 对应（§3.4） |
| `COPY`（`copy_in` / `CopyWriter`） | 无直接对应 | 批量 INSERT；或读 CDC 做增量搬运 |
| `Connection::backend_pid` / `server_version` | 本地嵌入式库没有 backend pid | `server_version` → `turso_version()` / `sqlite_version()`（当前 3.50.4）；`backend_pid` 去掉 |
| TLS / `sslmode` | 本地库没有传输层 | 去掉；远程同步走 HTTPS（在 sync 层） |

## 3. Turso 特有的扩展（加在基础接口之上）

**3.1 错误档位要覆盖状态码**。`PgError` 只有三档不够；Turso 的 `turso_status_code_t` 需要映射成：

```
TursoError {
  ConnectionError(String)   // TURSO_NOTADB / TURSO_ERROR ...
  QueryError(String)        // 语法/类型错误
  NoRows
  Busy                      // TURSO_BUSY（锁忙，可重试）
  Conflict                  // TURSO_BUSY_SNAPSHOT（MVCC 写写冲突，可重试）
  Constraint(String)        // TURSO_CONSTRAINT
  ReadOnly / Full / Corrupt / Interrupt / Misuse ...
}
```

关键是把 **`Conflict` 和 `Busy` 单列**——它们是「可重试」信号，上层重试逻辑靠它们判断。

**3.2 `BEGIN CONCURRENT` 与重试**（最重要的扩展）。

- `TxOptions{mode: Concurrent}` 或独立的 `conn.begin_concurrent()`。Go 绑定就在这栽过：`BeginTx` 硬编码普通 `BEGIN` 且忽略选项，用户拿不到 MVCC 并发写。
- 加 `retry_func(beginner, opts, fn)`：只对 `Conflict` / `Busy` 重试，**带 full-jitter 指数退避**。默认 `Attempts=10`、`1ms → 50ms`——理由见附一的「MVCC 重试多少次合适」：实测无退避时 8 个写者抢同一行平均要 ~94 次尝试，加退避只要 ~2.6 次。**千万别不加退避地紧循环重试**（附二 §2(a)：等待写锁 733ms 就烧掉 0.99 个核）。

**3.3 按连接的 PRAGMA 便捷入口**：`set_journal_mode(mvcc|wal)`、`busy_timeout(ms)`、`query_only`、`optimize` 等。注意这些都是**连接级**状态，别做成全局。

**3.4 CDC（承接 moonpg 的 LISTEN/NOTIFY 位置）**：`conn.capture_data_changes(mode)` 开启，然后轮询 `turso_cdc` 表（`change_type` 1=INSERT 0=UPDATE -1=DELETE 2=COMMIT，v2 带 `change_txn_id`）。两个约束：按连接开启；**CDC 开着时不能切 journal_mode**。

**3.5 向量检索**：`Row::get_vector(k)` + 构造辅助 `vector32/64/8/1bit/sparse`；距离函数 `vector_distance_cos/l2/dot/jaccard`。这是 Turso 相对 SQLite 的原生扩展，也是替换 `pgtype` 那套 codec 体系之后的「类型扩展点」。

**3.6 同步（Turso Cloud / 离线优先）**：独立的 `SyncDatabase { connect, push, pull, checkpoint, stats }`（对应 Go 的 `NewTursoSyncDb`）。注意它来自**另一个 C 头** `sync/sdk-kit/turso_sync.h`，且 Push/Pull 与 Checkpoint 不能并发。

**3.7 其它 C API 直接给到的能力**：`enable_load_extension` / `load_extension`、`register_scalar_function` / `register_aggregate_function` / `register_collation`（moonpg 没有对应）、`PRAGMA wal_checkpoint`、`EXPLAIN QUERY PLAN`。

## 4. 架构上的根本差异（建议写进 README）

moonpg 的卖点是 **“pure MoonBit, wire protocol from scratch, zero C dependencies”**；而 Turso 绑定**必然是 C 绑定**（核心是 Rust，只暴露 C ABI）。所以：

- **包结构不同**：需要 `native-stub` + 仅 native 的 `ffi.mbt` + 链接 `-lturso`（见附二 §3）；moonpg 那边是 `supported_targets = "+native"` 的纯 MoonBit 代码，没有 stub。
- **生命周期要引 finalizer**：`turso_database_t*` / `turso_connection_t*` / `turso_statement_t*` 有各自的 `*_deinit`，用 external object + finalizer 兜底，别指望用户手动释放。
- **async 是最大的落差，而且只能做到「交错」而非「重叠」**（详见 §6）。
- 因此 `Connection::status` / `is_closed` 这类观测方法可以保留，但语义按本地库重写。

## 5. 建议的包结构（对齐 moonpg 的文件划分）

```
moon.mod / moon.pkg     // preferred_target = "native"；native-stub + ffi 仅 native
ffi.mbt                 // extern "c" 声明（仅 native）
stub.c                  // moonbit.h 胶水：句柄包装、finalizer、字符串拷贝
turso.mbt               // 核心 trait：QueryExecutor / Rows / Tx / TxBeginner / Closer + TursoError
conn.mbt                // Connection / connect() / PRAGMA 便捷入口
row.mbt                 // Row / ExecResult / Row::get
values.mbt              // ToValue / FromValue（5 种存储类型）
from_row.mbt            // FromRow + 元组实现（照搬 moonpg 的 2~10 元组）
tx.mbt                  // TxMode / TxOptions / begin_func / retry_func
cdc.mbt                 // CDC 扩展
vector.mbt              // 向量扩展
sync.mbt                // 同步扩展（可选，独立 C 头）
```

测试用例直接采用附二 §5 那份清单（它就是从 Go 绑定的实测坑里提炼的）。

## 6. 两个常被问到的点（多连接 / async）

### 6.1 一个 Database 可以开出多个 Connection

是的，而且这是**主要用法**：`turso_database_new` → `turso_database_open` → `turso_database_connect` **可重复调用**，每次都得到一个独立的 `turso_connection_t*`。

- 每个连接**同一时刻只能有一个事务**；要并发写 N 个事务，就得有 N 个连接（MVCC 下配合 `BEGIN CONCURRENT`）。
- 所以 MoonBit 侧应当把 `Database::connect()` 设计成可反复调用的方法，而「池」的职责就是**限制/复用**这些连接（§2 的 Pool 行已按此改写）。
- 参考实现：Go 绑定每个物理连接都会 new+open+connect 一个 database handle，靠进程内的 database registry 按路径去重、共享底层实例；同一路径的多个 handle 之间仍然是协调一致的。

### 6.2 同步 C ABI 能不能接 async fd 做单线程并发？

**结论：能拿到「交错（interleaving）」，拿不到「重叠（overlap）」。**

先看 C ABI 给了什么（`turso.h` / `sdk-kit/src/rsapi.rs`）：

```c
typedef struct { /* ... */ uint64_t async_io; const char *vfs; /* ... */ } turso_database_config_t;
turso_status_code_t turso_statement_run_io(const turso_statement_t *self, const char **error_opt_out);
```

```rust
/// if true, library methods will return Io status code and delegate Io loop to the caller
/// if false, library will spin IO itself in case of Io status code and never return it to the caller
pub async_io: bool,
```

- `async_io = true` 的含义是「**由调用方决定何时推进 I/O 循环**」：语句返回 `TURSO_IO`，你去调 `turso_statement_run_io()` 推进一步。注意文档措辞是 “execute **one iteration** of underlying IO backend”——**这次调用本身还是会做 I/O**。
- C ABI **没有暴露任何自定义 IO 的入口**：`turso.h` 里只有 `async_io` 和 `vfs`（`memory` / `syscall` / `io_uring` / `experimental_win_iocp`），没有任何 IO vtable、也没有把待处理 fd / completion 交还给调用方的途径。而 Rust 原生 API 里**有** `pub io: Option<Arc<dyn IO>>`（外加 `db_file: Option<Arc<dyn DatabaseStorage>>`）——但 C ABI 转换时被硬编码成 `io: None`（`rsapi.rs:556`）。

因此：

- 你**无法**把这个库接到 `epoll` / `io_uring` 的事件循环上等「可读/可写」事件——因为拿不到 fd，也没有「完成通知」的回调。
- 单线程里你能做的是**协作式轮转**：维护「哪个语句在等 I/O」的队列，轮流调 `run_io`，期间可以 `yield` 给 async 运行时。这能提升**公平性/吞吐利用率**，但一次 `run_io` 阻塞在磁盘上时，同一线程里的其他连接也只能等——所以是**交错，不是重叠**。
- 也正因为没有「等待」原语，**一旦你在循环里反复调 `run_io` 而不让出，就会烧 CPU**：实测（Go 绑定就是这么写的）等待写锁 733ms 就吃掉 **0.99 个核**。
- 想要真正的并行 I/O，现实选择只有：**多线程**（每个线程跑自己的 run_io 循环，Go 的 8 连接并发就是这么来的——cgo 阻塞时运行时会另开 OS 线程），或者**推动上游在 C ABI 暴露自定义 IO**（把 `io` 字段透出来），那才是绑定层做真 async 的前提。

给 MoonBit 的建议：

1. 先用 `async_io = true` + 自己实现的「语句就绪队列」+ 每步 `yield`，拿到交错的并发度；
2. 阻塞点用线程池隔离（如果 `moonbitlang/async` 支持 worker 线程），这是当前唯一能得到真并行的路子；
3. 若要用 `vfs = "io_uring"`，注意它对调用方仍是同步语义，只是内核侧更高效；
4. 把「C ABI 暴露自定义 IO」当成一条上游需求记下来——Rust 侧已有该能力，只是没透到 C。

### 6.3 基于 `moonbitlang/async` **0.22.4** 的结论（2026-10 核查）

> 版本对照：`jaredzhou/moonpg` 目前 pin 的是 `moonbitlang/async@0.19.0`；本节基于 **v0.22.4** 的源码
> （clone 在 `/tmp/async-0224`，tag `v0.22.4`）。

**0.22.4 新增了两个和这件事直接相关的东西：**

1. **`RawFdStream`**（`src/raw_fd/`，0.19 没有）：带缓冲的 fd 流 —— `read_until` / `read_exactly` /
   `read_some` / `read_all` / `write_once` / `write_reader`，并实现了 `@io.Reader` / `@io.Writer`。
   比裸 `RawFd` 更适合做「请求/响应」式的通知通道。
2. **`moonbitlang/async/external_loop_integration`**（新包）：

   ```moonbit
   pub(open) trait ExternalEventLoop {
     fn poll(Self, timeout? : Int) -> Unit raise
     fn get_wakeup_callback_for_foreign_thread(Self) -> FuncRef[() -> Unit]
     fn terminate(Self) -> Unit raise
   }
   pub fn set_external_event_loop(&@external_loop_integration.ExternalEventLoop) -> Unit
   ```

   用途是「宿主自带事件循环（GUI 等），MoonBit 的 async loop 跑在专用线程，由宿主的 `poll` 驱动」。
   其中 `get_wakeup_callback_for_foreign_thread()` 是**官方认可的跨线程唤醒原语**，它的测试实现就是
   **pipe**（Unix）/ **event**（Windows）。原文档还给了一条硬性约束，写 Turso 的 `stub.c` 时要照办：

   > the returned wakeup callback will be invoked in a dedicated thread, so the callback **MUST NOT** do
   > anything other than invoking a C FFI function directly, and that invoked C FFI function must not
   > perform any MoonBit reference counting operation.

**另一个关键事实：`is_async=false` 的 fd 会自动走运行时的内部线程池。** 源码 `src/internal/event_loop/io.mbt`：

```
/// - `is_async=true`: support native async operations through the event bus.
/// - `is_async=false`: all operations are blocking and go through the thread pool
```

而 `RawFd::RawFd(fd)` / `RawFdStream::RawFdStream(fd)` 的做法是：检查该 fd **是否已经是非阻塞**（`fd_is_nonblocking`），
据此决定走哪条路；`is_async=true` 时会把它设成非阻塞并注册进 event bus（epoll）。也就是说：**给它的 fd 阻塞与否都能用**，
阻塞的话运行时用自己的线程池帮你兜住——所以通知管道不需要我们自己管线程。

#### 结论：能并发，但「接的是自己的管道，不是 Turso 的 fd」

| 问题 | 答案 |
| --- | --- |
| 把 **Turso 自己的 db/WAL fd** 接进 async 事件循环、做真 async I/O？ | ❌ 不行。C ABI 不交出 fd，也没有自定义 IO 入口（`io: None` 硬编码）；与 async 版本无关 |
| 在**单线程事件循环**里并发跑多个 Turso 连接、且不忙等？ | ✅ 可以。用「后台线程跑阻塞调用 + pipe 唤醒」，MoonBit 侧 await 管道即可 |
| 需要自己管线程吗？ | 通知管道那边不用（运行时线程池兜底）；**跑 Turso 阻塞调用的那个线程要自己起**（运行时没有公开的 `spawn_blocking`） |

推荐架构（各连接一个 actor，互不共享 Turso 句柄）：

```
MoonBit task ──(请求)──▶ C stub 队列 ──▶ 工作线程：turso_statement_step / run_io（阻塞）
      ▲                                              │
      └────────── await RawFdStream::read ◀── pipe 写 1 字节（完成通知）
```

- 每个 Turso 连接**固定在一个工作线程**上（C ABI 没有线程安全承诺，主线程不要碰它）。
- 唤醒用 pipe：C 侧写、MoonBit 侧 `RawFd`/`RawFdStream` 读；**不要**在 `TURSO_IO` 上忙等（§附二 2(a)）。
- 若宿主本身已有事件循环（GUI / C·Rust 宿主嵌 MoonBit），改用 `set_external_event_loop` +
  `get_wakeup_callback_for_foreign_thread()`，这是官方支持的形态。

#### 「后台线程」到底从哪来？（澄清一个常见误解）

先说结论：**moonbitlang/async 的「任务调度」是单线程的，但运行时内部并不单线程。**

- **单线程的部分**：所有 MoonBit async 任务都在**同一个事件循环线程**上协作式调度。所以 MoonBit 值不需要锁，
  用户代码没有数据竞争。
- **运行时内部的线程**：事件循环初始化时会调 `init_thread_pool_ffi(bus)`（`internal/event_loop/event_loop.mbt:78`）
  起一个 **C 侧工作线程池**，按需 spawn（`EventLoop::new(max_worker_count~)`，`max_worker_count` 默认 **1024**）。
  它用来兜住「没法用 epoll 异步做」的操作。源码很直白 —— `internal/event_loop/io.mbt`：

  ```moonbit
  } else if handle.is_async {
    handle.read_via_event_bus(buf, offset~, len~, context~)
  } else {
    handle.read_via_worker(buf, offset~, len~, context~)   // → perform_job_in_worker(...)
  }
  ```

  而 `is_async=false` 的典型来源是**普通文件**：`fs.mbt` 里 `is_async = access is 3 || kind.can_poll()`，
  普通文件不可 poll → 走 worker 线程池。**这些 worker 只执行 C 代码，不运行 MoonBit 代码**，
  这也是为什么整套东西对 MoonBit 侧仍是「单线程」语义。

所以「后台线程」有三处来源，别混：

| 来源 | 谁创建 | 用途 | 我们要不要管 |
| --- | --- | --- | --- |
| ① 运行时自带的工作线程池 | 运行时（`init_thread_pool_ffi`） | 它自己的阻塞 fd 操作（普通文件等） | **不用管**：把一个阻塞 fd 交给 `RawFd`/`RawFdStream` 就会自动用它 |
| ② 我们在 `stub.c` 里起的线程 | 我们自己 | 跑 Turso 的阻塞 `prepare`/`step`/`run_io` | **要自己起**：运行时没有公开 API 把「任意阻塞函数」提交给它的池 |
| ③ `ExternalEventLoop` 模式下的 loop 线程 | 运行时 | 宿主自带 loop 时，把 MoonBit 的 loop 放到专用线程 | 不用管，只有那个模式才涉及 |

为什么 Turso 蹭不到 ①：那个池只接受它自己内部的 `Job`（read/write/...），整个包在 `internal/` 下，
**没有公开入口**让你塞一个任意 C 函数进去。所以「Turso 的阻塞调用」必须在 ② 里跑。

**Turso 的 `.so` 会不会替你开工作线程？不会。** 三条证据：

1. `turso.h` 里与线程相关的只有 `async_io` 这一个开关，没有任何线程/线程池/worker API。
2. **`async_io` 的两种模式都在「调用线程」上跑** —— `sdk-kit/src/rsapi.rs` 的 `step_inner` 说得最清楚：

   ```rust
   StepResult::IO | StepResult::Yield | StepResult::Sleep { .. } => {
       if async_io {
           Ok(TursoStatusCode::Io)     // 交还调用方：由你决定何时推进
       } else {
           stmt._io().step()?;         // ← 在【当前线程】上直接把 I/O 做掉
           continue;
       }
   }
   ```

   默认 `async_io=false` 时库「自己 spin IO」（Rust 注释原话），但那是在**调用线程**上 spin；
   `async_io=true` 时返回 `TURSO_IO`，也是**你在调用线程上**调 `run_io`。两种模式都不换线程。
3. 核心里的 `thread::spawn` 逐个查过，**全部落在各自的 `mod tests` 里**（`core/vdbe/mod.rs`、
   `core/storage/pager.rs`、`core/storage/shared_wal_coordination.rs`）——生产路径不替你开线程。

> 对比 Go：Go 之所以「免费」拿到线程，是 **Go runtime 的机制**（cgo 调用阻塞时运行时会另开 OS 线程）。
> 那不是 Turso 给的。MoonBit 没有这个机制：它的内部线程池只服务它自己的 fd 操作，且在 `internal/` 下。

**而且 MoonBit 侧也没有现成的起线程 API**：`moonbitlang/core` 没有公开的 thread 包，
`moonbitlang/async` 0.22.4 的公开接口里也没有 `spawn_blocking` / worker 之类的入口。
所以这个工作线程只能在 **`stub.c` 里用 `pthread_create`（Windows 用 `CreateThread`/`_beginthreadex`）自己起**
——这正好契合 MoonBit C 绑定用 `native-stub` 放 C 代码的写法。

分工因此是清楚的：**`.so` 负责「谁调它就在谁的线程上阻塞做完」，线程、job 队列、结果槽、门铃 pipe 都是你的活**；
运行时只管通知管道那条 fd 的等待（阻塞 fd 自动走它的内部池）和 MoonBit 任务调度。

### 6.4 为什么 `async_io=true` 也**接不进**事件循环？（关键澄清）

「既然有 `async_io=true`，直接接到 `moonbitlang/async` 不就行了？」——很自然的想法，但**`async_io` 交出的不是 I/O 本身，
只是「何时调用 `run_io`」这个调度权**。四条证据：

1. **`syscall` VFS 下 `run_io` 是空操作。** `core/io/unix.rs`：

   ```rust
   fn step(&self) -> Result<()> { Ok(()) }        // UnixIO::step：什么都不做
   fn pread(&self, pos: u64, c: Completion) -> Result<Completion> {
       let r = unsafe { libc::pread(...) };        // ← 真正的阻塞 read 在这里，发起时就做完了
   ```

   也就是说：I/O 在**发起那一刻就同步做完了**，`step()` 自然无事可做。所以 `async_io=true` 在这种后端下纯属形式，
   阻塞发生在 `stmt.step()` 内部。
2. **`io_uring` VFS 下 `step()` 会等。** `core/io/io_uring.rs` 的 `step()` 走 leader 路径
   （`submit_and_wait` + 排空 CQE，注释里叫 “keep draining until the ring is empty”）。io_uring 省的是**系统调用开销**，
   不是「不阻塞」。
3. **C ABI 没把 waker / completion 暴露出来。** Rust 侧有 `step_with_waker` 和 per-completion 的 waker
   （`step_inner(stmt, async_io, waker)`），但 `turso.h` 里 grep `waker|completion|pending` 全空。
   调用方既拿不到「哪个 fd 就绪了」，也无从把它注册进 epoll。
4. **`Sleep` 的时长信息被丢掉。** `rsapi.rs` 的 `step_inner` 把
   `StepResult::IO | Yield | Sleep { .. }` **一起**映射成 `TursoStatusCode::Io`，所以调用方无法区分
   「现在该做一次 read」和「该等 100ms」——这正是 Go 绑定忙等烧 CPU 的根源（§附一）。

**结论**：直接接进事件循环最多只能拿到**协作式交错**（在两次 `run_io` 之间让出），**拿不到重叠**——
任何一次 `run_io`/`step` 阻塞在磁盘上，整个 loop 都停住。

**真正缺的是「把 I/O 的发起与完成交给调用方」的能力**，即 Rust 侧的 `io: Option<Arc<dyn IO>>`
（自己实现 `open_file` / `pread` / `pwrite` / `sync`，就能把 fd 交给 epoll），而 C ABI 把它硬编码成 `io: None`
（`sdk-kit/src/rsapi.rs:556`）。

**而且 Turso 自己证明这个设计可行**：**同步引擎**的 C API 就是「调用方执行 I/O」模型
（`sync/sdk-kit/turso_sync.h`）——它把请求描述交给你，你自己做完再回报：

```c
turso_sync_io_request_type_t turso_sync_database_io_request_kind(const turso_sync_io_item_t *self);
turso_status_code_t turso_sync_database_io_request_http(const turso_sync_io_item_t *self, turso_sync_io_http_request_t *request);
turso_status_code_t turso_sync_database_io_request_full_read(const turso_sync_io_item_t *self, turso_sync_io_full_read_request_t *request);
turso_status_code_t turso_sync_database_io_status(const turso_sync_io_item_t *self, int32_t status);
turso_status_code_t turso_sync_database_io_push_buffer(const turso_sync_io_item_t *self, turso_slice_ref_t *buffer);
turso_status_code_t turso_sync_database_io_done(const turso_sync_io_item_t *self);
```

**同步这条链路把 I/O 交出来了（HTTP 请求 / 整块读 / 整块写），本地存储这条链路没有。** 这既解释了为什么现在必须
自己起线程，也给出了最直接的上游需求：把本地存储的 I/O 也按同样方式透出来（或至少开放 `io` 字段）。

#### 附：C 侧到底要写多少代码？（已实测）

`examples/c-abi-worker/mini_worker.c` 是一个**可编译、可运行**的最小骨架（150 行含注释，`gcc -Wall -Wextra` 零警告），
做的就是本节描述的方案：

- 每连接一个 `pthread`，连接钉在该线程上（actor），**不做池**；
- `async_io = 0`，在 worker 线程里跑 `prepare → step/run_io` 的循环；
- 结果写进加锁的结果槽 → **再**往 `pipe()` 写 1 字节（门铃）；
- 主线程用阻塞 `read()` 模拟 MoonBit 侧的 `RawFdStream::read` 等待。

实测输出：

```
[心跳] 事件循环线程仍在跑别的任务 #1      ← 工作线程阻塞查询期间，心跳线程照常被调度
...
结果：conn0 = 42 conn1 = 123
```

链接方式（本机 Turso C 库随 Go SDK 分发，`nm -D` 确认导出 77 个 `turso_*` 符号）：

```bash
SO_DIR=/home/jared/go/pkg/mod/github.com/tursodatabase/turso-go-platform-libs@v0.8.2/libs/linux_amd64
gcc -O1 -Wall -Wextra -o /tmp/mini_worker mini_worker.c \
    -I/tmp/turso-src/sdk-kit -L"$SO_DIR" -lturso_sync_sdk_kit -lpthread
LD_LIBRARY_PATH="$SO_DIR" /tmp/mini_worker
```

### 6.5 要不要做线程池？

**第一版不需要。** 用「**每连接一个线程**」就够，理由是它把复杂度消掉了：

| | 每连接一个线程（推荐） | 固定大小线程池 |
| --- | --- | --- |
| 连接与线程的关系 | 一一对应（actor），天然独占 | 需要把连接钉到某个 worker，或加 per-connection 锁 |
| 共享状态 | 无（每个 worker 只有自己的连接 + 结果槽） | 需要共享 job 队列（mutex + condvar） |
| 代码量 | ~150 行（见上面示例） | 多出调度/绑定/公平性逻辑 |
| 线程数 | = 连接数 | 固定，可控 |
| 适用 | 连接数几十以内（大多数嵌入式场景） | 连接数上百、或要限制并发度 |

什么时候才需要池：① 连接数会到上百、不想让线程数线性增长；② 需要限制「同时进 Turso 的并发度」；
③ 连接是短命的、创建销毁频繁。**注意即使上了池，也必须保证「同一连接同一时刻只被一个线程使用」**。

### 6.6 C 不好写怎么办？两条替代路线

如果对 C 不熟，可以整个把「工作线程 + 生命周期管理」挪到 Rust 里：

1. **Rust 写一个薄封装**（用 `rsapi::TursoDatabase` 这类**安全**的 Rust API），在里面用 `std::thread` +
   `channel` 做 offload，然后只导出 3~4 个 `extern "C"` 函数给 MoonBit（`spawn_worker` / `submit` /
   `take_result` / `shutdown`）。这样所有权、panic、清理都由 Rust 兜住，C 侧只剩一层极薄的 shim；
   编译成 `cdylib` 后用 `link.native("cc-link-flags": ["-L...", "-lturso_helper"])` 链接即可
   （MoonBit 支持链接预编译库，见附二 §3）。
2. **接受现成实现的接线方式**：Go SDK 的 `driver_db.go` 就是「调用方自己管线程」的样板（它把线程交给 Go
   runtime），可以照着读一遍再翻译。**不要把 Go 那套 `executeFully` 紧循环照抄过来** —— 那是忙等（附二 §2(a)）。

另外，C 侧真正容易出错的不是线程本身（`pthread_create` + mutex + condvar 就够），而是：
**内存/生命周期（没有 Rust 的所有权帮你）、错误路径的清理、以及门铃的 drain 语义**。
如果这三样你觉得吃力，选第 1 条（Rust 封装）更稳。

### 6.7 跨线程传数据的规则（从 MoonBit GC 的实现看）

问：MoonBit 是单线程模型，工作线程通过 FFI 传数据会不会出问题？
**会——如果乱传。但规则很明确：MoonBit 值不是「共享」的，跨线程只能「移动」或「拷贝」。**

先看实现（`~/.moon/lib/runtime/runtime.c` 与 `~/.moon/include/moonbit_runtime.h`）：

1. **refcount 是普通读改写，不是原子操作**：

   ```c
   MOONBIT_EXPORT void moonbit_decref(void *ptr) {
     int32_t const rc = header->rc;
     if (raw_rc_is_shared(rc)) {
       header->rc = rc - MOONBIT_RC_COUNT_UNIT;   // ← 非原子 RMW
       MOONBIT_ADD_POSSIBLE_ROOT(ptr);
     } ...
   ```

   低 5 位还被用来存 block kind 与**循环回收的记账位**（注释：*logical count 变化 1 → raw word 变化 32*）。
2. **decref 还会顺带改对象头、并在需要时登记循环回收根**：`moonbit_possible_root` 会 `set_cycle_status(...)`，
   必要时调 `moonbit_push_root(ptr)` —— 而头文件明确写着 push_root **“may allocate”**。
3. **整个 `runtime.c` 里没有任何 thread / mutex / atomic 相关代码。**

两条并发 decref 同一对象 → 丢更新（泄漏或提前释放 / UAF）。所以规则是：

| 规则 | 说明 | 依据 |
| --- | --- | --- |
| **同一 MoonBit 对象同一时刻只能被一个线程持有** | 跨线程是 **move（`#owned` 所有权转移）**，不是 share | 运行时自己的线程池就是范例：`Job` 以 `#owned` 交给 C，worker 里直接 `moonbit_decref`（`internal/event_loop/thread_pool.c:722` 等）——那一刻 MoonBit 侧已不再持有它 |
| **唤醒回调里禁止 refcount** | 官方硬性警告：回调在专用线程执行，**只能直接调 C FFI，且该 C 函数不得做任何 MoonBit 引用计数** | `external_loop_integration/external_loop.mbt` 的 IMPORTANT 注记 |
| **不要在 worker 线程分配 MoonBit 对象** | `moonbit_make_bytes` 等是往 GC 堆分配并走循环记账，超出 FFI 约定 | 同上 |
| **`#borrow`/`Bytes` 只在调用期间有效** | worker 不能留用调用返回后的指针 | `moonbit-c-binding` 的所有权约定 |

**给 Turso 绑定的安全做法（推荐照抄）**：跨线程只传**纯 C 内存**。

- `submit(sql, params)` 在 **MoonBit 线程上**把 SQL/参数 `malloc` + `memcpy` 拷进 C 缓冲（因为 `#borrow` 的指针出了调用就失效）；
- worker 只碰 **C 内存 + pipe**，完全不触碰 MoonBit 对象；
- 唤醒后，**在 MoonBit 线程上**调一个 FFI 把结果**从 C 缓冲拷进** `Bytes`/`String`（拷贝发生在 MoonBit 线程 → 合法）。

这样既不需要 `#owned` 的所有权转移，也不会碰到 refcount / 循环回收的任何簿记 —— `examples/c-abi-worker/mini_worker.c`
就是这个形状（结果放在加锁的 C struct 里，calling 方拷出来）。

#### 最小形态与坑（确认整体形状）

**C 侧（`stub.c`）**

- 每个连接一个工作线程 + 一个**结果槽** + 一个 pipe（Linux 上也可用 `eventfd`，天然合并计数）；
- MoonBit 侧提交 job（SQL/参数拷进 job；注意 MoonBit `Bytes`/`String` 的生命周期）→ 唤醒工作线程；
- 工作线程跑 `prepare → bind → step/run_io` 直到结束，把结果写进结果槽（加锁），再往 pipe 写 1 字节；
- **顺序很关键**：先发布结果，再写门铃字节（用锁或 release 语义保证可见性）。

**MoonBit 侧**

```moonbit nocheck
let bell = RawFdStream(pipe_read_fd)     // 阻塞 fd → 自动走运行时线程池；非阻塞 → 走 epoll，都行
submit(conn, sql, params)                // 交给工作线程，立即返回
bell.read_exactly(1)                     // 挂起等待；此期间事件循环照常跑别的任务
// 醒来后：drain 掉管道里所有字节，再逐个检查哪些连接的结果槽非空
```

**坑（按踩到的概率排）**

1. **一次通知 ≠ 一个完成。** 醒来必须把管道里的字节**全部 drain**，并检查**所有**连接的 pending 结果，
   否则会丢唤醒（deadlock）。
2. **结果槽要加锁/原子**，且发布顺序是「先结果、后门铃」。
3. **同一个连接不能被两个线程同时使用**，要钉在一个工作线程上（actor 模型）。
   不同连接并行是安全的——Go 那边 8 个连接并发写就是多 OS 线程同时进 Turso，实测可行。
4. **阻塞调用只能发生在工作线程上。** 只要有一次 `turso_statement_step` 落在事件循环线程上，
   整个 loop 就被卡住（这正是我们要避免的）。
5. **取消/超时**：任务被取消时要让工作线程放弃，或至少标记结果无人认领，
   别让结果槽被下一次提交覆盖。
6. 门铃的**写端建议非阻塞**（或直接用 `eventfd`），避免极端情况下写端阻塞工作线程。
