// 设计稿：事务 + 重试助手（Turso 特有的 BEGIN 变体都在这里体现）。

///|
/// `BEGIN` 的模式。
///
/// 前三个与 SQLite 一一对应：
///
/// - `Deferred`：默认，事务真正开始拿锁推迟到第一条读写语句。
/// - `Immediate`：立刻拿写锁（WAL 下即「预留写」），拿不到就 `Busy`。
/// - `Exclusive`：立刻拿排他锁。
///
/// `Concurrent` 是 **Turso 扩展**（`BEGIN CONCURRENT`，只在 MVCC 下有意义）：
/// 多个写事务可以同时进行，提交时做乐观冲突检测，冲突方拿 `Conflict`
/// （C 侧 `TURSO_BUSY_SNAPSHOT`，事务已被中止，必须整事务重试）。
pub(all) enum TxMode {
  Deferred
  Immediate
  Exclusive
  Concurrent
} derive(Eq, Debug)

///|
/// `begin_tx` 的选项。
///
/// 这里**不是** moonpg 的 `isolation_level`：SQLite/Turso 只控制「何时拿锁」，
/// 不提供隔离级别选择。
pub(all) struct TxOptions {
  mode : TxMode?
  read_only : Bool?
} derive(Eq, Debug)

///|
/// 默认选项：`mode = Deferred`、非只读。
declare pub fn TxOptions::default() -> TxOptions

///|
/// 进行中的事务。继承 `QueryExecutor`，所以在事务里 query/execute 的写法和
/// 在连接上完全一样。
pub(open) trait Tx: QueryExecutor {
  async fn commit(Self) -> Unit raise TursoError
  async fn rollback(Self) -> Unit raise TursoError
}

///|
/// 能开事务的东西：`Connection` / `Pool` / `PoolConn`。
pub(open) trait TxBeginner {
  async fn begin_tx(Self, opts? : TxOptions) -> &Tx raise TursoError
}

///|
/// 重试预算（full-jitter 指数退避）。
///
/// 默认值来自实测：两个连接抢 MVCC 写时，不退避平均 ~94 次尝试才成功，
/// 带 jitter 只要 ~2.6 次。
///
/// - `attempts`：尝试次数上限。
/// - `base_delay_ms` / `max_delay_ms`：退避区间（第 n 次的上限是
///   `min(base * 2^n, max)`，实际等待在 `[0, 上限]` 里随机取）。
/// - `budget_ms`：总时间预算，超了就放弃（`None` 表示只按次数算）。
pub(all) struct RetryOptions {
  attempts : Int32
  base_delay_ms : Int32
  max_delay_ms : Int32
  budget_ms : Int32?
} derive(Eq, Debug)

///|
declare pub fn RetryOptions::default() -> RetryOptions

///|
/// 开事务 → 跑 `f` → 成功 commit，抛错 rollback（吞掉 rollback 自己的错）后
/// 把原错误重新抛出。
declare pub async fn[T, B : TxBeginner] begin_func(
  beginner : B,
  f : async (&Tx) -> T,
) -> T raise TursoError

///|
/// `begin_func` + 重试，只重试 **`Conflict`**（MVCC 写写冲突：事务已被中止，
/// 只能整个重开）。
///
/// 注意语义：`f` 会被**执行多次**，所以事务里做的事必须可重复执行
/// （必要时用唯一键/版本号保护，别把「已经发出去的副作用」放在里面）。
declare pub async fn[T, B : TxBeginner] retry_tx(
  beginner : B,
  f : async (&Tx) -> T,
  opts? : RetryOptions,
) -> T raise TursoError

///|
/// 语句级重试，只重试 **`Busy`**（WAL 写锁忙）。
///
/// 非 MVCC 模式下并发写本来就是靠忙等/重试收敛的，所以这个助手的意义是
/// 「把忙等待交给调用方控制」，而不是「避免失败」。
/// 接收者用 `&QueryExecutor`（不是 `&Connection`）：MoonBit 里 `&T` 的 `T` 必须是
/// trait；而且这样 `Pool` / `PoolConn` 也能直接用，与 `fetch` 的写法一致。
declare pub async fn[T] retry_stmt(
  exec : &QueryExecutor,
  f : async (&QueryExecutor) -> T,
  opts? : RetryOptions,
) -> T raise TursoError
