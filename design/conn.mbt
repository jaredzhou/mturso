// 设计稿：句柄层（Database = 连接池 / Connection = 一次 checkout）。

///|
/// 一个 Turso 数据库 = 一个连接池（ADR-0001）。
///
/// 它持有 idle / busy 连接；`max_conns` 是**线程预算**（一条连接 = 一个 C 侧
/// worker）。它自己也实现 `QueryExecutor` / `TxBeginner`：`db.query(...)` /
/// `db.begin_tx()` 是隐式 acquire/release。
declare pub type Database

///|
/// 一次 checkout。独立的语句/事务状态，独占一个 C 侧工作线程。
///
/// 实现里它持有自己所属的 `Database`（结构体字段构成 GC 可达引用，防止库先被
/// 回收、连接变成悬空句柄）。
declare pub type Connection

///|
/// 打开数据库。`max_conns` 是池上限（默认 4）。
declare pub fn Database::open(
  path : String,
  max_conns? : Int,
) -> Database raise TursoError

///|
/// 从池里取一条连接。**async**：`max_conns` 满时会等待别人归还。
declare pub async fn Database::connect(
  self : Database,
) -> Connection raise TursoError

///|
/// 关闭数据库（幂等）：**级联**关掉 idle 和 busy 里的所有连接（join 各自 worker），
/// 再 `turso_database_deinit`。签名是 `-> Unit`（不抛），所以可以 `defer db.close()`。
declare pub fn Database::close(self : Database) -> Unit

///|
declare pub fn Database::is_closed(self : Database) -> Bool

///|
/// 池上限（线程预算）。
declare pub fn Database::max_conns(self : Database) -> Int

///|
/// 池统计快照（定义在 pool.mbt）。
declare pub fn Database::stats(self : Database) -> PoolStats

///|
// ---------------------------------------------------------------------------
// Connection

///|
/// 关闭连接 = **还回池**（幂等；不是销毁）。
declare pub fn Connection::close(self : Connection) -> Unit

///|
/// 连接是否已关闭（已还回池也算关闭）。
declare pub fn Connection::is_closed(self : Connection) -> Bool

///|
/// 最近一次 INSERT 生成的 rowid。
declare pub fn Connection::last_insert_rowid(self : Connection) -> Int64

///|
/// 引擎自报的版本串。注意这是**兼容性伪装**：它回答的是它兼容的 SQLite 版本
/// （实测 `3.50.4`），不是 Turso 自己的版本号。
declare pub async fn Connection::sqlite_version(
  self : Connection,
) -> String raise TursoError

///|
// ---------------------------------------------------------------------------
// trait impl 带出的方法（declare pub impl 不带出方法，这里单独声明一遍）。

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
) -> DbTx raise TursoError

///|
declare pub impl QueryExecutor for Connection

///|
declare pub impl TxBeginner for Connection

///|
declare pub impl Closer for Connection

///|
// ---------------------------------------------------------------------------
// Database 作为池：隐式 acquire/release

///|
declare pub async fn Database::query(
  self : Database,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise TursoError

///|
declare pub async fn Database::query_one(
  self : Database,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise TursoError

///|
declare pub async fn Database::execute(
  self : Database,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise TursoError

///|
declare pub async fn Database::begin_tx(
  self : Database,
  opts? : TxOptions,
) -> DbTx raise TursoError

///|
declare pub impl QueryExecutor for Database

///|
declare pub impl TxBeginner for Database

///|
// ---------------------------------------------------------------------------
// 库级设置（journal_mode 是文件属性，唯一入口是「从某条连接发 PRAGMA」）

///|
/// 引擎真正支持（`JournalMode::supported()`）的 journal mode 就这两个。
pub(all) enum JournalMode {
  Wal
  Mvcc
} derive(Eq, Debug)

///|
/// 设置这个库的 journal mode（内部借一条连接发 `PRAGMA journal_mode=...`）。
///
/// **不是廉价的运行时开关**：真正改变模式会先做一次**全量 checkpoint 并
/// Truncate**（WAL 要完全清空）、改写文件头的 read/write version、清 page cache；
/// 切到 `Mvcc` 还会打开 `.db-log` 并 bootstrap。同值再设是 no-op。所以尽量在
/// `open` 时定一次，别频繁切。
///
/// journal_mode 是**库/文件级**属性，所以它挂在 `Database` 而不是 `Connection` 上。
///
/// **联动**：设成 `Mvcc` 时把本库的默认事务模式设为 `TxMode::Concurrent`，
/// `Wal` 则设回 `Deferred`。之后再手动 `set_default_tx_mode` 会覆盖它（后调用的赢）。
declare pub fn Database::set_journal_mode(
  self : Database,
  mode : JournalMode,
) -> Unit raise TursoError

///|
/// 默认事务模式：`begin_tx` 在 `opts.mode == None` 时用它。库刚打开时是 `Deferred`。
declare pub fn Database::set_default_tx_mode(
  self : Database,
  mode : TxMode,
) -> Unit

///|
/// 读回当前默认事务模式。
declare pub fn Database::default_tx_mode(self : Database) -> TxMode
