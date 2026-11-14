// Public query and execute entry points.

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
/// 打开一个流式行读取器（读一个算一个，不物化）。
async fn Connection::open_rows(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
  release? : Connection,
) -> ResultRows raise TursoError {
  self.ensure_open()
  let encoded = @utf8.encode(sql)
  let stmt = @ffi.conn_prepare_first(self.raw, encoded)
  check_error()
  // query 只接受单语句：tail 之后除空白/分号外不能再有内容
  let mut extra = false
  for i in @ffi.stmt_tail(stmt).to_int()..<encoded.length() {
    let c = encoded[i].to_int()
    if c != 59 && c != 32 && c != 10 && c != 13 && c != 9 {
      extra = true
    }
  }
  if extra {
    raise TursoError::QueryError(
      "query() accepts a single statement; use execute() for scripts",
    )
  }
  bind_params(stmt, params)
  let fd = @ffi.submit_stmt_rows(self.raw, stmt)
  check_error()
  let stream = @raw_fd.RawFdStream(fd) catch {
    _ => {
      @ffi.conn_wait_job(self.raw)
      raise TursoError::ConnectionError("failed to wrap result fd")
    }
  }
  // 先把 HEADER 拉下来：列信息，顺便把执行期的错误在返回前暴露出来
  errdefer {
    stream.close()
    @ffi.conn_wait_job(self.raw)
  }
  let (tag, payload) = read_frame(stream)
  match tag {
    1 => ()
    3 => raise stream_error(payload)
    _ => raise TursoError::QueryError("unexpected first frame tag \{tag}")
  }
  {
    stream,
    columns: parse_columns(payload),
    stmt,
    conn: self.raw,
    sync_io: self.sync_io,
    release,
    pending: None,
    pending_raw: None,
    changes: 0L,
    done: false,
    closed: false,
  }
}

///|
pub impl QueryExecutor for Connection with fn query(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise TursoError {
  self.open_rows(sql, params?)
}

///|
async fn Connection::await_execute(
  self : Connection,
  stmt : @ffi.Stmt,
) -> Int64 raise TursoError {
  let fd = @ffi.submit_stmt_execute(self.raw, stmt)
  check_error()
  let stream = @raw_fd.RawFdStream(fd) catch {
    _ => {
      @ffi.conn_wait_job(self.raw)
      raise TursoError::ConnectionError("failed to wrap execute fd")
    }
  }
  defer {
    stream.close()
    @ffi.conn_wait_job(self.raw)
  }
  for ;; {
    let (tag, payload) = read_frame(stream)
    match tag {
      0 => {
        if payload.length() < 8 {
          raise TursoError::QueryError("truncated execute result")
        }
        let rd : Rd = { b: payload, p: 0, }
        return rd.i64()
      }
      3 => raise stream_error(payload)
      4 =>
        match self.sync_io {
          Some(io) => {
            io.process_one()
            @ffi.conn_resume_sync_io(self.raw)
            continue
          }
          None => {
            raise TursoError::ConnectionError(
              "sync I/O requested by a local connection",
            )
          }
        }
      _ => raise TursoError::QueryError("unexpected execute frame tag \{tag}")
    }
  }
}

///|
/// Execute one or more statements through Turso's dedicated execute ABI.
pub impl QueryExecutor for Connection with fn execute(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise TursoError {
  self.ensure_open()
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
    let stmt = self.prepare_params(piece, params?)
    defer @ffi.stmt_deinit(stmt)
    total = total + self.await_execute(stmt)
    start = start + tail
  }
  { changes: total, }
}

///|
pub impl Fetching for Connection

///|
pub extend Connection with Fetching::{fetch, fetch_one}
