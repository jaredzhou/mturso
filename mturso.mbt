// mturso：Turso Database 的 MoonBit 绑定（C ABI，native）。
//
// 层次：`Database`（一个库）→ `Connection`（可开多个，各自独立的事务/语句状态）。
// 目前的调用是**同步**的（在调用线程上阻塞）——下一步会挪到工作线程 + 门铃 pipe，
// 并让查询变成 `async fn`（见 notes/turso-binding-guide.md §6）。

///|
/// 绑定层错误。
pub suberror MtursoError {
  MtursoError(String)
}

///|
/// 数据库句柄。一个 `Database` 可以开出多个 `Connection`。
pub struct Database {
  raw : @ffi.Db
}

///|
/// 连接句柄。
///
/// 注意 `db` 字段不是摆设：它让连接**持有数据库的引用**。否则 GC 可能先回收
/// `Database`，其 finalizer 一释放底层资源，连接就变成悬空句柄。
pub struct Connection {
  db : Database
  raw : @ffi.Conn
}

///|
/// 读取 FFI 侧的错误槽：非空就抛。
fn check_error() -> Unit raise MtursoError {
  let msg = @utf8.decode_lossy(@ffi.last_error())
  if msg != "" {
    raise MtursoError(msg)
  }
}

///|
/// 打开数据库：`":memory:"` 或文件路径。
///
/// ```mbt nocheck
/// let db = @mturso.Database::open(":memory:")
/// ```
pub fn Database::open(path : String) -> Database raise MtursoError {
  let raw = @ffi.db_open(@utf8.encode(path))
  check_error()
  { raw, }
}

///|
/// 开一个连接（可多次调用，各连接状态独立）。
///
/// ```mbt nocheck
/// let c1 = db.connect()
///
/// let c2 = db.connect()
/// ```
pub fn Database::connect(self : Database) -> Connection raise MtursoError {
  let raw = @ffi.db_connect(self.raw)
  check_error()
  { db: self, raw, }
}

///|
/// 关闭数据库（幂等）。
pub fn Database::close(self : Database) -> Unit {
  @ffi.db_close(self.raw)
}

///|
/// 执行 INSERT/UPDATE/DELETE/DDL，返回受影响行数。
pub fn Connection::exec(
  self : Connection,
  sql : String,
) -> Int64 raise MtursoError {
  let changes = @ffi.conn_exec(self.raw, @utf8.encode(sql))
  check_error()
  changes
}

///|
/// 执行查询，返回制表符分隔的文本（每行一条记录）。
pub fn Connection::query(
  self : Connection,
  sql : String,
) -> String raise MtursoError {
  let result = @ffi.conn_query(self.raw, @utf8.encode(sql))
  check_error()
  @utf8.decode_lossy(result)
}

///|
/// 关闭连接（幂等）。
pub fn Connection::close(self : Connection) -> Unit {
  @ffi.conn_close(self.raw)
}
