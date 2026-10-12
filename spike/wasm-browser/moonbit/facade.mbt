// spike 版「mini mturso」：只为证明**用户程序**的形状 —— 用户写 `Connection::query(sql)`，
// 编译成 wasm，引擎在宿主侧。真正的 mturso wasm backend 就是这个样子（把 ffi/ 换成这层）。

///|
pub struct Connection {
  path : String
}

///|
pub fn connect(path : String) -> Connection {
  { path, }
}

///|
/// 跑一条查询，返回「行内制表符、行间换行」的文本（与 native 绑定同一约定）。
pub fn Connection::query(self : Connection, sql : String) -> String {
  let _ = self
  let bytes = @utf8.encode(sql)
  if host_exec(bytes, bytes.length()) < 0 {
    return ""
  }
  let n = host_result_len()
  if n <= 0 {
    return ""
  }
  let buf : FixedArray[Byte] = FixedArray::make(n + 1, b'\x00')
  let got = host_result_copy(buf, n + 1)
  if got <= 0 {
    return ""
  }
  @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:got])
}

///|
/// 跑 DDL/DML（本 spike 里忽略影响行数）。
pub fn Connection::execute(self : Connection, sql : String) -> Unit {
  let _ = self.query(sql)
}

///|
pub fn Connection::close(self : Connection) -> Unit {
  let _ = self
}
