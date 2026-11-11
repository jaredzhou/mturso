// 设计稿：事务 + 重试助手（Turso 特有的 BEGIN 变体都在这里体现）。

///|
/// `BEGIN` 的模式。前三个与 SQLite 一一对应；`Concurrent` 是 Turso 的
/// `BEGIN CONCURRENT`（只在 MVCC 下有意义；非 MVCC 下会**硬报错**）。
pub(all) enum TxMode {
  Deferred
  Immediate
  Exclusive
  Concurrent
} derive(Eq, Debug)

///|
/// `begin_tx` 的选项。`mode = None` 表示用库级默认
/// （`Database::default_tx_mode()`，见 conn.mbt）。
pub(all) struct TxOptions {
  mode : TxMode?
  read_only : Bool?
} derive(Eq, Debug)

///|
declare pub fn TxOptions::default() -> TxOptions

///|
/// 进行中的事务：只管 commit / rollback，**不**继承 `QueryExecutor`。
/// 具体事务类型（`DbTx`）同时实现 `QueryExecutor` 和 `Tx`，两个能力正交。
pub(open) trait Tx {
  async fn commit(Self) -> Unit raise TursoError
  async fn rollback(Self) -> Unit raise TursoError
}

///|
/// 具体事务。参考 moonpg：连接版与池版**合并成同一个具体类型**，所以
/// `begin_tx` 对所有实现者都返回 `DbTx` —— `&TxBeginner` 仍然可用，同时
/// `tx.execute(...)` / `tx.commit()` 都是普通 dot 调用。
///
/// 池版将来在结构里带一个可选的 `pool_conn`，commit/rollback 时顺便还连接。
declare pub type DbTx

///|
declare pub async fn DbTx::query(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise TursoError

///|
declare pub async fn DbTx::query_one(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise TursoError

///|
declare pub async fn DbTx::execute(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise TursoError

///|
declare pub async fn DbTx::commit(self : DbTx) -> Unit raise TursoError

///|
declare pub async fn DbTx::rollback(self : DbTx) -> Unit raise TursoError

///|
declare pub impl QueryExecutor for DbTx

///|
declare pub impl Tx for DbTx

///|
/// 能开事务的东西：`Connection` / `Database`（池）。两者都返回同一个 `DbTx`。
pub(open) trait TxBeginner {
  async fn begin_tx(Self, opts? : TxOptions) -> DbTx raise TursoError
}

///|
/// 重试预算（full-jitter 指数退避）。
pub(all) struct RetryOptions {
  attempts : Int
  base_delay_ms : Int
  max_delay_ms : Int
  budget_ms : Int?
} derive(Eq, Debug)

///|
declare pub fn RetryOptions::default() -> RetryOptions

///|
/// 开事务 → 跑 `f` → 成功 commit，抛错 rollback（吞掉 rollback 自己的错）后
/// 把原错误重新抛出。
declare pub async fn[T, B : TxBeginner] begin_func(
  beginner : B,
  f : async (DbTx) -> T raise TursoError,
) -> T raise TursoError

///|
/// `begin_func` + 重试。重试单位是**整个事务**；重试的是「可重试」那一档
/// （`Busy` | `Conflict`），撞到哪个取决于连接的运行模式。
///
/// 没有语句级重试助手：读不需要重试（直接 `conn.query()`），写要能重试就显式走事务。
declare pub async fn[T, B : TxBeginner] retry_tx(
  beginner : B,
  f : async (DbTx) -> T raise TursoError,
  opts? : RetryOptions,
) -> T raise TursoError
