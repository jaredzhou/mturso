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
/// **级联**：先关掉本库开出的所有连接（join 掉各自的工作线程），再
/// `turso_database_deinit`（见 ADR-0001）。签名是 `-> Unit`（不抛、幂等），
/// 所以可以 `defer db.close()`。
declare pub fn Database::close(self : Database) -> Unit

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
/// journal_mode 是**库/文件级**属性（两个连同一文件的连接看到的是同一个模式），
/// 所以它挂在 `Database` 而不是 `Connection` 上 —— 否则每条连接各记一份默认值，
/// 会跟库的真实状态漂移。
///
/// **联动**：设成 `Mvcc` 时把本库的默认事务模式设为 `TxMode::Concurrent`，
/// `Wal` 则设回 `Deferred` —— 因为 MVCC 下普通 `BEGIN` 走 exclusive 路径、
/// 并发写会 `Busy`，`BEGIN CONCURRENT` 才是 MVCC 该有的默认。之后再手动
/// `set_default_tx_mode` 会覆盖它（后调用的赢）。
declare pub fn Database::set_journal_mode(
  self : Database,
  mode : JournalMode,
) -> Unit raise TursoError

///|
/// 默认事务模式：`begin_tx` 在 `opts.mode == None` 时用它。库刚打开时是 `Deferred`。
/// 由本库开出的所有连接共享。
declare pub fn Database::set_default_tx_mode(
  self : Database,
  mode : TxMode,
) -> Unit

///|
/// 读回当前默认事务模式。
declare pub fn Database::default_tx_mode(self : Database) -> TxMode
