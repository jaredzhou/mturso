// 流式行集：C 侧把结果按帧推进 pipe（布局见 `ffi/stub.c` 的 `stream_query_rows`），
// 这里从 `RawFdStream` **拉** —— 读一个、算一个，不物化。

///|
/// 拉取式行读取器（本版是**流式**实现：`has_next` 才去读下一帧）。
pub(open) trait Rows {
  async fn has_next(Self) -> Bool raise TursoError
  fn get_row(Self) -> Row raise TursoError
  fn columns(Self) -> Array[@value.Column]
  /// 同步、不抛、幂等 —— 关掉读端就等于取消（worker 的 write 拿到 EPIPE 就停）。
  fn close(Self) -> Unit
}

///|
/// 流式行集。
pub struct ResultRows {
  stream : @raw_fd.RawFdStream
  columns : Array[@value.Column]
  stmt : @ffi.Stmt
  conn : @ffi.Conn
  pending : Ref[Array[@value.Value]?]
  changes : Ref[Int64]
  done : Ref[Bool]
  closed : Ref[Bool]
}

///|
pub impl Rows for ResultRows with has_next(self) {
  if self.closed.val || self.done.val {
    return false
  }
  let (tag, payload) = read_frame(self.stream)
  match tag {
    0 => {
      self.done.val = true
      if payload.length() >= 8 {
        let rd : Rd = { b: payload, p: Ref(0) }
        self.changes.val = rd.i64()
      }
      false
    }
    2 => {
      self.pending.val = Some(parse_cells(payload, self.columns.length()))
      true
    }
    3 => {
      self.done.val = true
      raise stream_error(payload)
    }
    _ => {
      self.done.val = true
      raise TursoError::QueryError("unexpected frame tag \{tag}")
    }
  }
}

///|
pub impl Rows for ResultRows with get_row(self) {
  match self.pending.val {
    Some(values) => {
      self.pending.val = None
      { values, columns: self.columns }
    }
    None => raise TursoError::QueryError("no pending row; call has_next() first")
  }
}

///|
pub impl Rows for ResultRows with columns(self) {
  self.columns
}

///|
pub impl Rows for ResultRows with close(self) {
  if !self.closed.val {
    self.closed.val = true
    // 关掉读端：worker 的 write 会拿到 EPIPE，立刻停下（这就是取消）
    self.stream.close()
    // 等 worker 真的停了，之后 stmt 才能安全释放
    @ffi.conn_wait_job(self.conn)
  }
}

///|
/// 让具体类型上的 `rows.has_next()` 这类 dot 调用也成立（不只是 `&Rows`）。
pub extend ResultRows with Rows::{has_next, get_row, columns, close}

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
/// 读一帧：`u8 tag + u32 len + payload`。返回 (tag, payload)。
async fn read_frame(s : @raw_fd.RawFdStream) -> (Int, Bytes) raise TursoError {
  let head = s.read_exactly(5) catch {
    _ => raise TursoError::ConnectionError("failed to read result frame")
  }
  let tag = head[0].to_int()
  let len = head[1].to_int() |
    (head[2].to_int() << 8) |
    (head[3].to_int() << 16) |
    (head[4].to_int() << 24)
  let payload = s.read_exactly(len) catch {
    _ => raise TursoError::ConnectionError("failed to read result payload")
  }
  (tag, payload)
}

///|
/// ERR 帧的 payload = `u8 kind + 消息`。
fn stream_error(payload : Bytes) -> TursoError {
  if payload.length() == 0 {
    return TursoError::QueryError("stream error")
  }
  kind_to_error(payload[0].to_int(), @utf8.decode_lossy(payload[1:].to_owned()))
}

///|
fn parse_columns(payload : Bytes) -> Array[@value.Column] raise TursoError {
  let rd : Rd = { b: payload, p: Ref(0) }
  let n = rd.u32()
  let cols : Array[@value.Column] = []
  for _ in 0..<n {
    let name = @utf8.decode_lossy(rd.bytes())
    let decltype = @utf8.decode_lossy(rd.bytes())
    cols.push({ name, decltype })
  }
  cols
}

///|
fn parse_cells(payload : Bytes, n_cols : Int) -> Array[@value.Value] raise TursoError {
  let rd : Rd = { b: payload, p: Ref(0) }
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
  vals
}

///|
/// 打开一个流式行读取器（读一个算一个，不物化）。
async fn Connection::open_rows(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> ResultRows raise TursoError {
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
  if fd < 0 {
    raise TursoError::ConnectionError("failed to start streaming query")
  }
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
    pending: Ref(None),
    changes: Ref(0L),
    done: Ref(false),
    closed: Ref(false),
  }
}

///|
pub impl QueryExecutor for Connection with query(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise TursoError {
  self.open_rows(sql, params?)
}
