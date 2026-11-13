// 参数绑定：prepare + bind 全在 MoonBit 侧（C 只是薄壳，不做任何编码）。

///|
/// 把一个 `Value` 绑到 `?pos`（1-based）。
fn bind_one(stmt : @ffi.Stmt, pos : Int, v : @value.Value) -> Unit {
  match v {
    @value.Value::Null => @ffi.stmt_bind_null(stmt, pos)
    @value.Value::Integer(i) => @ffi.stmt_bind_int(stmt, pos, i)
    @value.Value::Real(d) => @ffi.stmt_bind_double(stmt, pos, d)
    @value.Value::Text(s) => @ffi.stmt_bind_text(stmt, pos, @utf8.encode(s))
    @value.Value::Blob(b) => @ffi.stmt_bind_blob(stmt, pos, b)
  }
}

///|
fn bind_params(
  stmt : @ffi.Stmt,
  params : Array[&ToValue]?,
) -> Unit raise TursoError {
  match params {
    None => ()
    Some(ps) => {
      let mut pos = 1
      for p in ps {
        bind_one(stmt, pos, p.to_value())
        check_error()
        pos = pos + 1
      }
    }
  }
}

///|
/// Prepare one statement and bind positional parameters (`?1`..).
fn Connection::prepare_params(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> @ffi.Stmt raise TursoError {
  self.ensure_open()
  let stmt = @ffi.conn_prepare(self.raw, @utf8.encode(sql))
  check_error()
  errdefer @ffi.stmt_deinit(stmt)
  bind_params(stmt, params)
  stmt
}
