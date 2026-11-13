// QueryExecutor 的另外两个方法：query_one / execute。

///|
/// 让 `conn.query(...)` / `conn.execute(...)` 这类 dot 调用成立。
pub extend Connection with QueryExecutor::{query, query_one, execute}

///|
/// 取第一行；零行抛 `NoRows`。
pub impl QueryExecutor for Connection with fn query_one(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise TursoError {
  let rows = self.query(sql, params?)
  defer rows.close()
  if rows.has_next() {
    return rows.get_row()
  }
  raise TursoError::NoRows
}

///|
/// Execute one or more statements through Turso's dedicated execute ABI.
pub impl QueryExecutor for Connection with fn execute(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise TursoError {
  let data = @utf8.encode(sql)
  let mut start = 0
  let mut total = 0L
  for ;; {
    while start < data.length() {
      let c = data[start].to_int()
      if c == 59 || c == 32 || c == 10 || c == 13 || c == 9 {
        start = start + 1
      } else {
        break
      }
    }
    if start >= data.length() {
      break
    }
    let rest = data[start:].to_owned()
    let probe = @ffi.conn_prepare_first(self.raw, rest)
    check_error()
    let tail = @ffi.stmt_tail(probe).to_int()
    @ffi.stmt_deinit(probe)
    if tail <= 0 {
      break
    }
    let piece = @utf8.decode_lossy(data[start:start + tail].to_owned())
    total = total + self.exec_params(piece, params?)
    start = start + tail
  }
  { changes: total, }
}

///|
pub impl Fetching for Connection

///|
pub extend Connection with Fetching::{fetch, fetch_one}
