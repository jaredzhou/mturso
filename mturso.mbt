// mturso：Turso Database 的 MoonBit 绑定（C ABI，native）。
//
// 这一层只做最薄的事：把 raw FFI 包成能用的 API。
// 目前的调用是**同步**的（在调用线程上阻塞）——下一步会挪到工作线程 + 门铃 pipe，
// 并让它变成 `async fn`（见 notes/turso-binding-guide.md §6）。

///|
/// 绑定层错误。
pub suberror MtursoError {
  MtursoError(String)
}

///|
/// 连接句柄。
///
/// 这是 facade 自己的类型（方法只能定义在类型归属的包里），
/// 内部持有 `ffi` 包的原始句柄。字段对外不可见。
pub struct Conn {
  raw : @ffi.Conn
}

///|
/// 读取并清空 FFI 侧的错误槽：非空就抛。
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
/// let conn = @mturso.Conn::open(":memory:")
/// ```
pub fn Conn::open(path : String) -> Conn raise MtursoError {
  let raw = @ffi.open(@utf8.encode(path))
  check_error()
  { raw, }
}

///|
/// 执行 INSERT/UPDATE/DELETE/DDL，返回受影响行数。
pub fn Conn::exec(self : Conn, sql : String) -> Int64 raise MtursoError {
  let changes = @ffi.exec(self.raw, @utf8.encode(sql))
  check_error()
  changes
}

///|
/// 执行查询，返回制表符分隔的文本（每行一条记录）。
pub fn Conn::query(self : Conn, sql : String) -> String raise MtursoError {
  let result = @ffi.query(self.raw, @utf8.encode(sql))
  check_error()
  @utf8.decode_lossy(result)
}

///|
/// 关闭连接（幂等）。
pub fn Conn::close(self : Conn) -> Unit {
  @ffi.close(self.raw)
}
