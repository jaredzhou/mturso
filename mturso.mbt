// mturso：Turso Database 的 MoonBit 绑定（C ABI，native）。
//
// 层次：`Database`（一个库）→ `Connection`（可开多个，各自独立的事务/语句状态）。
//
// 执行模型（见 notes/turso-binding-guide.md §6）：
//   - `query` / `exec` 是 **async**：语句交给**每连接一个工作线程**执行（阻塞只发生在那里），
//     完成后往该连接的门铃 pipe 写 1 字节，这里的 `RawFdStream::read` 挂起等待 →
//     事件循环线程全程不被卡住，可以继续跑别的任务。
//   - `query_blocking` / `exec_blocking` 是同步版本：在调用线程上直接跑，不需要 async 运行时。

///|
/// 值类型从子包转出，使用方只写 `@mturso.Value` / `@mturso.Column`
/// （错误类型在 errors.mbt，值这一层的 trait 在 traits.mbt）。
pub using @value {type Value, type Column}

///|
/// 数据库句柄。一个 `Database` 可以开出多个 `Connection`。
pub struct Database {
  raw : @ffi.Db
}

///|
/// 连接句柄。
///
/// - `db` 字段不是摆设：它让连接**持有数据库的引用**，否则 GC 可能先回收 `Database`，
///   其 finalizer 一释放底层资源，连接就成了悬空句柄。
/// - `bell` 是门铃的懒加载包装（`RawFdStream` 的构造是 async，所以只能在第一次用到时建）。
pub struct Connection {
  db : Database
  raw : @ffi.Conn
  bell : Ref[@raw_fd.RawFdStream?]
}

///|
/// 读取 FFI 侧的错误槽：非空就抛。
fn check_error() -> Unit raise TursoError {
  let msg = @utf8.decode_lossy(@ffi.last_error())
  if msg != "" {
    raise TursoError(msg)
  }
}

///|
/// 打开数据库：`":memory:"` 或文件路径。
///
/// ```mbt nocheck
/// let db = @mturso.Database::open(":memory:")
/// ```
pub fn Database::open(path : String) -> Database raise TursoError {
  let raw = @ffi.db_open(@utf8.encode(path))
  check_error()
  { raw, }
}

///|
/// 开一个连接（可多次调用，各连接状态独立，各自有一个工作线程）。
///
/// ```mbt nocheck
/// let c1 = db.connect()
///
/// let c2 = db.connect()
/// ```
pub fn Database::connect(self : Database) -> Connection raise TursoError {
  let raw = @ffi.db_connect(self.raw)
  check_error()
  { db: self, raw, bell: { val: None, }, }
}

///|
/// 关闭数据库（幂等）。
pub fn Database::close(self : Database) -> Unit {
  @ffi.db_close(self.raw)
}

///|
/// 关闭连接（幂等；会唤醒并回收它的工作线程）。
pub fn Connection::close(self : Connection) -> Unit {
  @ffi.conn_close(self.raw)
}

///|
/// 懒创建门铃流（只在本连接的第一次异步调用时建一次）。
async fn Connection::bell_stream(
  self : Connection,
) -> @raw_fd.RawFdStream raise TursoError {
  match self.bell.val {
    Some(stream) => stream
    None => {
      let fd = @ffi.conn_bell_fd(self.raw)
      check_error()
      let stream = @raw_fd.RawFdStream(fd) catch {
        _ => raise TursoError("failed to create doorbell stream")
      }
      self.bell.val = Some(stream)
      stream
    }
  }
}

///|
/// 等待工作线程敲门铃（`read_exactly` 抛的是通用 `Error`，这里转成 `TursoError`）。
async fn await_bell(bell : @raw_fd.RawFdStream) -> Unit raise TursoError {
  ignore(bell.read_exactly(1)) catch {
    _ => raise TursoError("doorbell read failed")
  }
}

///|
/// 执行查询（异步）。返回制表符分隔的文本（每行一条记录）。
///
/// 语句在工作线程上执行；这里 await 门铃，事件循环可以继续跑别的任务。
pub async fn Connection::query(
  self : Connection,
  sql : String,
) -> String raise TursoError {
  let bell = self.bell_stream()
  @ffi.submit_query(self.raw, @utf8.encode(sql))
  check_error()
  await_bell(bell) // 挂起等待 worker 敲门铃
  let result = @ffi.take_query(self.raw)
  check_error()
  @utf8.decode_lossy(result)
}

///|
/// 执行 INSERT/UPDATE/DELETE/DDL（异步）。返回受影响行数。
pub async fn Connection::exec(
  self : Connection,
  sql : String,
) -> Int64 raise TursoError {
  let bell = self.bell_stream()
  @ffi.submit_exec(self.raw, @utf8.encode(sql))
  check_error()
  await_bell(bell)
  let changes = @ffi.take_exec(self.raw)
  check_error()
  changes
}

///|
/// 同步版查询：在调用线程上直接跑（不需要 async 运行时）。
pub fn Connection::query_blocking(
  self : Connection,
  sql : String,
) -> String raise TursoError {
  let result = @ffi.conn_query(self.raw, @utf8.encode(sql))
  check_error()
  @utf8.decode_lossy(result)
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
