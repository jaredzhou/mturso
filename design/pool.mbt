// 设计稿：连接池。
//
// 池的意义是**线程预算**：一个连接 = 一个 C 侧工作线程，池就是把「同时能用
// 多少个线程」变成显式的配置。

///|
/// 池配置。
///
/// - `max_conns`：上限（含在用 + 空闲）；`acquire()` 超出就**等待**。
/// - `min_idle`：建池时就先建好这么多空闲连接。
/// - `max_idle_sec`：空闲超过这个秒数的连接会被回收（连带回收它的工作线程）。
///
/// moonpg 里的 `health_check` / `max_lifetime_sec` / `maintenance_interval_sec`
/// 这一版不做（Turso 侧没有 `status()` 这种廉价的健康检查，也不需要后台维护循环）。
pub(all) struct PoolConfig {
  max_conns : Int
  min_idle : Int
  max_idle_sec : Int
} derive(Eq, Debug)

///|
/// 建配置（全部有默认值）。
declare pub fn PoolConfig::new(
  max_conns? : Int,
  min_idle? : Int,
  max_idle_sec? : Int,
) -> PoolConfig

///|
/// 池的观测数据。
pub(all) struct PoolStats {
  total_connections : Int
  idle_connections : Int
  active_connections : Int
  acquire_count : Int64
  acquire_wait_count : Int64
  acquire_wait_duration_ms : Int64
} derive(Eq, Debug)

///|
/// 连接池。持有它所属的 `Database`（GC 可达性；不是 Rust 那种借用）。
declare pub type Pool

///|
/// 从池里借出来的一条连接。用完必须 `release()`（重复 release 幂等）。
declare pub type PoolConn

///|
/// 建池：`min_idle` 条连接会立刻建好（每条都是一个 C 侧线程）。
declare pub async fn Pool::new(
  db : Database,
  config? : PoolConfig,
) -> Pool raise TursoError

///|
/// 显式取一条连接；达到 `max_conns` 时**等待**别人归还（不抛 Busy）。
declare pub async fn Pool::acquire(self : Pool) -> PoolConn raise TursoError

///|
/// 归还连接（幂等；被标记为坏掉的连接会被真正 close 掉、回收线程）。
declare pub fn PoolConn::release(self : PoolConn) -> Unit

///|
declare pub fn Pool::stats(self : Pool) -> PoolStats

///|
declare pub fn Pool::total(self : Pool) -> Int

///|
declare pub fn Pool::idle(self : Pool) -> Int

///|
/// 关闭池：回收池里**所有**连接的 C 侧工作线程；不会关掉 `db`。
declare pub fn Pool::close(self : Pool) -> Unit

///|
/// 池上直接跑 SQL = 隐式 acquire/release（用完自动归还）。
// 同 conn.mbt：`declare pub impl` 不带出方法，方法单独 declare 一遍。

///|
declare pub async fn Pool::query(
  self : Pool,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise TursoError

///|
declare pub async fn Pool::query_one(
  self : Pool,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise TursoError

///|
declare pub async fn Pool::execute(
  self : Pool,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise TursoError

///|
declare pub async fn Pool::begin_tx(
  self : Pool,
  opts? : TxOptions,
) -> &Tx raise TursoError

///|
declare pub async fn PoolConn::query(
  self : PoolConn,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise TursoError

///|
declare pub async fn PoolConn::query_one(
  self : PoolConn,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise TursoError

///|
declare pub async fn PoolConn::execute(
  self : PoolConn,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise TursoError

///|
declare pub async fn PoolConn::begin_tx(
  self : PoolConn,
  opts? : TxOptions,
) -> &Tx raise TursoError

///|
declare pub fn PoolConn::close(self : PoolConn) -> Unit

///|
declare pub impl QueryExecutor for Pool

///|
declare pub impl TxBeginner for Pool

///|
declare pub impl Closer for Pool

///|
declare pub impl QueryExecutor for PoolConn

///|
declare pub impl TxBeginner for PoolConn

///|
declare pub impl Closer for PoolConn

///|
/// 池上 `query()` 返回的行读取器：它带着那条 `PoolConn`，读完（或 close）时
/// 自动把连接还给池——这就是「隐式释放」的实现方式。
declare pub type PoolRows

///|
declare pub impl Rows for PoolRows

///|
/// 池上的事务：`commit`/`rollback` 之后自动把连接还给池。
declare pub type PoolDbTx

///|
declare pub impl Tx for PoolDbTx
