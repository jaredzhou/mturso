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
/// 执行语句（本版单语句）：复用 `query` 的读帧路径，把结果集排空，
/// 受影响行数来自 END 帧。
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
    let rows = self.open_rows(piece, params?)
    while rows.has_next() {
      ignore(rows.get_row())
    }
    rows.close()
    total = total + rows.changes.val
    start = start + tail
  }
  { changes: total, }
}

///|
/// Execute one statement with dynamically decoded values.
pub async fn Connection::execute_values(
  self : Connection,
  sql : String,
  params : Array[@value.Value],
) -> ExecResult raise TursoError {
  let rows = self.query_values(sql, params)
  while rows.has_next() {
    ignore(rows.get_row())
  }
  rows.close()
  { changes: rows.changes(), }
}

///|
pub impl Fetching for Connection

///|
pub extend Connection with Fetching::{fetch, fetch_one}
