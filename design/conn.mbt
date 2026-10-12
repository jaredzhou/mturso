// 设计稿：句柄层（Database / Connection）与它的观测方法。

///|
/// 一个 Turso 数据库（文件路径或 `":memory:"`）。
///
/// 它是**连接工厂**：一个库可以开出多个 `Connection`；但它自己不实现
/// `QueryExecutor` / `TxBeginner`（要跑 SQL 必须先开连接）。
declare pub type Database

///|
/// 一个连接：独立的语句/事务状态，并且**独占一个 C 侧工作线程**。
///
/// 实现里它会持有自己所属的 `Database`（结构体字段构成 GC 可达引用，
/// 防止库先被回收、连接变成悬空句柄）。
declare pub type Connection

///|
/// 打开数据库。
declare pub fn Database::open(path : String) -> Database raise TursoError

///|
/// 开一个连接。
declare pub fn Database::connect(self : Database) -> Connection raise TursoError

///|
/// 关闭数据库（之后不能再用它开连接）。
///
/// **还有活着的 `Connection` 时抛 `TursoError::ConnectionError`**：C 侧的
/// `turso_database_deinit` 要求之后没人再碰这个 database，而显式 close 是逻辑
/// 动作、GC 挡不住 use-after-free，所以这里必须显式挡掉。
/// 顺序：先 `Pool::close()` / `conn.close()`，再 `db.close()`。
declare pub fn Database::close(self : Database) -> Unit raise TursoError

///|
/// 连接是否已关闭（不抛：用来做幂等检查）。
declare pub fn Connection::is_closed(self : Connection) -> Bool

///|
/// 最近一次 INSERT 生成的 rowid。
declare pub fn Connection::last_insert_rowid(self : Connection) -> Int64

///|
/// 引擎自报的版本串。注意这是**兼容性伪装**：它回答的是它兼容的 SQLite 版本
/// （实测 `3.50.4`），不是 Turso 自己的版本号。
declare pub fn Connection::sqlite_version(self : Connection) -> String

///|
// ---------------------------------------------------------------------------
// 下面几个方法在实现里由 trait impl 提供（`pub impl QueryExecutor for Connection
// with fn ...`，一份就够）。设计稿里 `declare pub impl` 不会带出方法，所以这里
// 单独 declare 一遍，好让用法片段真的能调用它们。

///|
declare pub async fn Connection::query(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise TursoError

///|
declare pub async fn Connection::query_one(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise TursoError

///|
declare pub async fn Connection::execute(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise TursoError

///|
declare pub async fn Connection::begin_tx(
  self : Connection,
  opts? : TxOptions,
) -> &Tx raise TursoError

///|
declare pub fn Connection::close(self : Connection) -> Unit

///|
declare pub impl QueryExecutor for Connection

///|
declare pub impl TxBeginner for Connection

///|
/// `Closer` 的签名是 `fn close(Self) -> Unit`（不抛、幂等）：
/// 确定性停掉并 join 掉工作线程；如果此刻正有一个语句在飞，会**等它跑完**
/// （Turso 没有跨线程取消的 API，这是唯一安全策略）。
declare pub impl Closer for Connection
