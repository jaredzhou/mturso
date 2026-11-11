// QueryExecutor 的另外两个方法：query_one / execute。

///|
/// 让 `conn.query(...)` / `conn.execute(...)` 这类 dot 调用成立。
pub extend Connection with QueryExecutor::{query, query_one, execute}

///|
/// 取第一行；零行抛 `NoRows`。
pub impl QueryExecutor for Connection with query_one(
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
pub impl QueryExecutor for Connection with execute(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise TursoError {
  let rows = self.open_rows(sql, params?)
  defer rows.close()
  while rows.has_next() {
    ignore(rows.get_row())
  }
  { changes: rows.changes.val, }
}

///|
pub impl Closer for Connection with close(self) {
  @ffi.conn_close(self.raw)
}
