// mturso：Turso Database 的 MoonBit 绑定（C ABI，native）。
//
// 层次：`Database`（一个库）→ `Connection`（可开多个，各自独立的事务/语句状态）。
//
// 执行模型：
//   - `query` / `query_one` / `execute` 是 async：prepare + bind 在 MoonBit 侧，
//     每连接一个 worker 只负责 step；结果按帧推进 socketpair，MoonBit 侧 pull
//     （读一个算一个，不物化）。
//   - `exec_blocking` 是同步版本：在调用线程上直接跑，不需要 async 运行时。

///|
/// 值类型从子包转出，使用方只写 `@mturso.Value` / `@mturso.Column`。
pub using @value { type Value, type Column }

///|
/// 数据库句柄。一个 `Database` 可以开出多个 `Connection`。
pub struct Database {
  raw : @ffi.Db
}

///|
/// 连接句柄。
///
/// `db` 字段不是摆设：它让连接**持有数据库的引用**，否则 GC 可能先回收 `Database`，
/// 其 finalizer 一释放底层资源，连接就成了悬空句柄。
pub struct Connection {
  db : Database
  raw : @ffi.Conn
}

///|
/// 读取 FFI 侧的错误槽：非空就抛（按 C 侧给的分类分型）。
fn check_error() -> Unit raise TursoError {
  let msg = @utf8.decode_lossy(@ffi.last_error())
  if msg != "" {
    raise kind_to_error(@ffi.last_error_kind(), msg)
  }
}

///|
/// C 侧的分类 → `TursoError` 构造器。
fn kind_to_error(kind : Int, msg : String) -> TursoError {
  match kind {
    2 => TursoError::Busy(msg)
    3 => TursoError::Conflict(msg)
    4 => TursoError::ConnectionError(msg)
    _ => TursoError::QueryError(msg)
  }
}

///|
/// 打开数据库：`":memory:"` 或文件路径。
pub fn Database::open(path : String) -> Database raise TursoError {
  let raw = @ffi.db_open(@utf8.encode(path))
  check_error()
  { raw, }
}

///|
/// 开一个连接（可多次调用，各连接状态独立，各自有一个 worker 线程）。
pub fn Database::connect(self : Database) -> Connection raise TursoError {
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
/// 关闭连接（幂等；会唤醒并回收它的 worker 线程）。
pub fn Connection::close(self : Connection) -> Unit {
  @ffi.conn_close(self.raw)
}

///|
/// 同步版 exec：在调用线程上直接跑（不需要 async 运行时）。
pub fn Connection::exec_blocking(
  self : Connection,
  sql : String,
) -> Int64 raise TursoError {
  let changes = @ffi.conn_exec(self.raw, @utf8.encode(sql))
  check_error()
  changes
}
