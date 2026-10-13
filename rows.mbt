// 物化行集：C 侧把结果按列类型缓冲成一段二进制（布局见 `ffi/stub.c` 的
// `do_query_rows`），这里解析成 columns + rows。

///|
/// 拉取式行读取器（本版是**物化**实现：整个结果集已在内存里；
/// 将来换成流式实现不需要改这个 trait）。
pub(open) trait Rows {
  async fn has_next(Self) -> Bool raise TursoError
  fn get_row(Self) -> Row raise TursoError
  fn columns(Self) -> Array[@value.Column]
  /// 同步、不抛、幂等 —— 就是为了能 `defer rows.close()`。
  fn close(Self) -> Unit
}

///|
/// 物化行集。
pub struct ResultSet {
  columns : Array[@value.Column]
  rows : Array[Array[@value.Value]]
  cursor : Ref[Int]
  closed : Ref[Bool]
}

///|
pub impl Rows for ResultSet with has_next(self) {
  !self.closed.val && self.cursor.val < self.rows.length()
}

///|
pub impl Rows for ResultSet with get_row(self) {
  if self.closed.val || self.cursor.val >= self.rows.length() {
    raise TursoError::QueryError("no more rows")
  }
  let values = self.rows[self.cursor.val]
  self.cursor.val = self.cursor.val + 1
  { values, columns: self.columns }
}

///|
pub impl Rows for ResultSet with columns(self) {
  self.columns
}

///|
pub impl Rows for ResultSet with close(self) {
  self.closed.val = true
}

// ---------------------------------------------------------------------------
// 二进制读游标（小端）
// ---------------------------------------------------------------------------

///|
priv struct Rd {
  b : Bytes
  p : Ref[Int]
}

///|
fn Rd::u8(self : Rd) -> Int raise TursoError {
  if self.p.val >= self.b.length() {
    raise TursoError::QueryError("truncated result buffer")
  }
  let v = self.b[self.p.val].to_int()
  self.p.val = self.p.val + 1
  v
}

///|
fn Rd::u32(self : Rd) -> Int raise TursoError {
  let mut v = 0
  for i in 0..<4 {
    v = v | (self.u8() << (8 * i))
  }
  v
}

///|
fn Rd::i64(self : Rd) -> Int64 raise TursoError {
  let mut v = 0L
  for i in 0..<8 {
    v = v | (self.u8().to_int64() << (8 * i))
  }
  v
}

///|
fn Rd::f64(self : Rd) -> Double raise TursoError {
  self.i64().reinterpret_as_double()
}

///|
fn Rd::bytes(self : Rd) -> Bytes raise TursoError {
  let n = self.u32()
  if self.p.val + n > self.b.length() {
    raise TursoError::QueryError("truncated result buffer")
  }
  let out = self.b[self.p.val : self.p.val + n].to_owned()
  self.p.val = self.p.val + n
  out
}

///|
/// 解析 C 侧的类型化二进制（布局见 `ffi/stub.c` 的 `do_query_rows`）。
fn parse_result(buf : Bytes) -> ResultSet raise TursoError {
  let rd : Rd = { b: buf, p: Ref(0) }
  let n_cols = rd.u32()
  let n_rows = rd.u32()
  let columns : Array[@value.Column] = []
  for _ in 0..<n_cols {
    let name = @utf8.decode_lossy(rd.bytes())
    let decltype = @utf8.decode_lossy(rd.bytes())
    columns.push({ name, decltype })
  }
  let rows : Array[Array[@value.Value]] = []
  for _ in 0..<n_rows {
    let vals : Array[@value.Value] = []
    for _ in 0..<n_cols {
      let kind = rd.u8()
      vals.push(
        match kind {
          1 => @value.Value::Integer(rd.i64())
          2 => @value.Value::Real(rd.f64())
          3 => @value.Value::Text(@utf8.decode_lossy(rd.bytes()))
          4 => @value.Value::Blob(rd.bytes())
          _ => @value.Value::Null
        },
      )
    }
    rows.push(vals)
  }
  { columns, rows, cursor: Ref(0), closed: Ref(false) }
}

///|
/// 同步：执行查询，返回**物化行集**。
///
/// 临时入口：`query` 现在还是旧的 TSV 文本接口，等切片 3 把它换成这个。
pub fn Connection::query_rows(self : Connection, sql : String) -> &Rows raise TursoError {
  let buf = @ffi.conn_query_rows(self.raw, @utf8.encode(sql))
  check_error()
  parse_result(buf)
}
