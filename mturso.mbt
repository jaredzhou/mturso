// mturso：Turso Database 的 MoonBit 绑定（C ABI，native）。
//
// 层次：`Database`（一个库 + 连接池，ADR-0001）→ `Connection`（池里的一次 checkout）。
//
// 执行模型：prepare + bind 在 MoonBit 侧，每连接一个 worker 只 step；
// 结果按帧推进单向 pipe，MoonBit 侧 pull（读一个算一个，不物化）。

///|
/// 值类型从子包转出，使用方只写 `@mturso.Value` / `@mturso.Column`。
pub using @value {type Value, type Column}

///|
/// Turso 支持的 journal mode。它是库/文件级属性，不是单连接属性。
#derive(Eq, Debug)
pub(all) enum JournalMode {
  Wal
  Mvcc
}

///|
/// 数据库句柄 = 一个连接池（见 ADR-0001）。
///
/// - `idle`：空闲连接的裸句柄（复用）；
/// - `busy`：借出中的裸句柄；`None` 是墓碑（已归还，槽位留着让索引稳定）；
/// - `sem`：`max_conns` 个许可，`connect()` 满了会等。
pub struct Database {
  priv raw : @ffi.Db
  priv max_conns : Int
  priv idle : Array[@ffi.Conn]
  priv idle_len : Ref[Int]
  priv busy : Array[@ffi.Conn?]
  priv sem : @async.Semaphore
  priv stats : Ref[PoolStats]
  priv journal_mode : Ref[JournalMode]
  priv default_tx_mode : Ref[TxMode]
  priv closed : Ref[Bool]
}

///|
/// 连接句柄（池里的一次 checkout）。
priv struct ConnectionLifetime {
  release : () -> Unit
  is_closed : () -> Bool
  default_tx_mode : () -> TxMode
}

///|
pub struct Connection {
  priv raw : @ffi.Conn
  priv mut lifetime : ConnectionLifetime
  priv closed : Ref[Bool]
  priv sync_io : SyncIoContext?
}

///|
/// 读取 FFI 侧的错误槽：非空就抛（按 C 侧给的分类分型）。
fn check_error() -> Unit raise TursoError {
  let msg = @utf8.decode_lossy(@ffi.last_error())
  if msg != "" {
    raise kind_to_error(@ffi.last_error_kind(), msg)
  }
}

///|
/// C 侧的分类 → `TursoError` 构造器。
fn kind_to_error(kind : Int, msg : String) -> TursoError {
  match kind {
    2 => TursoError::Busy(msg)
    3 => TursoError::Conflict(msg)
    4 => TursoError::ConnectionError(msg)
    _ =>
      // Turso 0.8.2 maps WriteWriteConflict to generic TURSO_ERROR instead of
      // TURSO_BUSY_SNAPSHOT; normalize the engine's exact message here.
      if msg == "Write-write conflict" {
        TursoError::Conflict(msg)
      } else {
        TursoError::QueryError(msg)
      }
  }
}

///|
/// 打开数据库。`max_conns` 是池上限（默认 4）。
pub fn Database::open(path : String, max_conns? : Int = 4) -> Database raise TursoError {
  let raw = @ffi.db_open(@utf8.encode(path))
  check_error()
  let n = if max_conns <= 0 { 1 } else { max_conns }
  {
    raw,
    max_conns: n,
    idle: [],
    idle_len: Ref(0),
    busy: [],
    sem: @async.Semaphore::Semaphore(n),
    stats: Ref({
      acquire_count: 0L,
      acquire_wait_count: 0L,
      acquire_wait_duration_ms: 0L,
    }),
    journal_mode: Ref(JournalMode::Wal),
    default_tx_mode: Ref(TxMode::Deferred),
    closed: Ref(false),
  }
}

///|
/// 只打开一条连接。内部持有 `max_conns = 1` 的私有 Database；关闭连接时
/// 私有 Database 也一起关闭。
pub async fn Connection::open(path : String) -> Connection raise TursoError {
  let db = Database::open(path, max_conns=1)
  errdefer db.close()
  let conn = db.connect()
  conn.lifetime = {
    release: () => db.close(),
    is_closed: () => db.closed.val,
    default_tx_mode: () => db.default_tx_mode.val,
  }
  conn
}

///|
fn Database::release_connection(
  self : Database,
  raw : @ffi.Conn,
  busy_index : Int,
) -> Unit {
  if self.closed.val {
    return
  }
  self.busy[busy_index] = None
  if self.idle_len.val < self.idle.length() {
    self.idle[self.idle_len.val] = raw
  } else {
    self.idle.push(raw)
  }
  self.idle_len.val = self.idle_len.val + 1
  self.sem.release()
}

///|
/// 从池里取一条连接：优先复用 idle；否则新建（受 `max_conns` 限制，满了等待）。
pub async fn Database::connect(self : Database) -> Connection raise TursoError {
  if self.closed.val {
    raise TursoError::ConnectionError("database is closed")
  }
  if self.sem.try_acquire() {
    let st = self.stats.val
    self.stats.val = {
      acquire_count: st.acquire_count + 1L,
      acquire_wait_count: st.acquire_wait_count,
      acquire_wait_duration_ms: st.acquire_wait_duration_ms,
    }
  } else {
    let t0 = @async.now()
    self.sem.acquire()
    let waited = @async.now() - t0
    let st = self.stats.val
    self.stats.val = {
      acquire_count: st.acquire_count + 1L,
      acquire_wait_count: st.acquire_wait_count + 1L,
      acquire_wait_duration_ms: st.acquire_wait_duration_ms + waited,
    }
  }
  let raw = if self.idle_len.val > 0 {
    self.idle_len.val = self.idle_len.val - 1
    self.idle[self.idle_len.val]
  } else {
    let r = @ffi.db_connect(self.raw)
    check_error()
    r
  }
  let idx = self.busy.length()
  self.busy.push(Some(raw))
  {
    raw,
    lifetime: {
      release: () => self.release_connection(raw, idx),
      is_closed: () => self.closed.val,
      default_tx_mode: () => self.default_tx_mode.val,
    },
    closed: Ref(false),
    sync_io: None,
  }
}

///|
/// 关闭连接 = **还回池**（幂等；不是销毁）。
pub fn Connection::close(self : Connection) -> Unit {
  if self.closed.val {
    return
  }
  self.closed.val = true
  (self.lifetime.release)()
}

///|
/// 连接是否已关闭（已还回池也算关闭）。
pub fn Connection::is_closed(self : Connection) -> Bool {
  self.closed.val
}

///|
/// 使用前检查：连接已还回 / 库已关 → `ConnectionError`。
fn Connection::ensure_open(self : Connection) -> Unit raise TursoError {
  if self.closed.val || (self.lifetime.is_closed)() {
    raise TursoError::ConnectionError("connection is closed")
  }
}

///|
/// 最近一次 INSERT 生成的 rowid。
pub fn Connection::last_insert_rowid(
  self : Connection,
) -> Int64 raise TursoError {
  self.ensure_open()
  let v = @ffi.conn_last_insert_rowid(self.raw)
  check_error()
  v
}

///|
/// 引擎自报的 SQLite 兼容版本（兼容性伪装，不是 Turso 自己的版本号）。
pub async fn Connection::sqlite_version(
  self : Connection,
) -> String raise TursoError {
  let rows = self.query("select sqlite_version()")
  defer rows.close()
  if rows.has_next() {
    let row = rows.get_row()
    let v : String = row.get(0)
    return v
  }
  raise TursoError::QueryError("sqlite_version returned no rows")
}

///|
/// 同步版 exec：在调用线程上直接跑（不需要 async 运行时）。
pub fn Connection::exec_blocking(
  self : Connection,
  sql : String,
) -> Int64 raise TursoError {
  self.ensure_open()
  let changes = @ffi.conn_exec(self.raw, @utf8.encode(sql))
  check_error()
  changes
}

///|
/// 关闭数据库（幂等）：**级联**关掉 idle 和 busy 里的所有连接（join 各自 worker），
/// 再 `turso_database_deinit`。
pub fn Database::close(self : Database) -> Unit {
  if self.closed.val {
    return
  }
  self.closed.val = true
  for i in 0..<self.idle_len.val {
    @ffi.conn_close(self.idle[i])
  }
  for i in 0..<self.busy.length() {
    match self.busy[i] {
      Some(raw) => @ffi.conn_close(raw)
      None => ()
    }
  }
  @ffi.db_close(self.raw)
}

///|
/// 数据库是否已关闭。
pub fn Database::is_closed(self : Database) -> Bool {
  self.closed.val
}

///|
/// 设置库级 journal mode，并联动默认事务模式：Mvcc → Concurrent，
/// Wal → Deferred。
pub fn Database::set_journal_mode(
  self : Database,
  mode : JournalMode,
) -> Unit raise TursoError {
  if self.closed.val {
    raise TursoError::ConnectionError("database is closed")
  }
  if self.journal_mode.val == mode {
    return
  }
  let raw = @ffi.db_connect(self.raw)
  defer @ffi.conn_close(raw)
  check_error()
  let pragma = match mode {
    JournalMode::Wal => "pragma journal_mode=wal"
    JournalMode::Mvcc => "pragma journal_mode=mvcc"
  }
  ignore(@ffi.conn_exec(raw, @utf8.encode(pragma)))
  check_error()
  self.journal_mode.val = mode
  self.default_tx_mode.val = match mode {
    JournalMode::Wal => TxMode::Deferred
    JournalMode::Mvcc => TxMode::Concurrent
  }
}

///|
/// 覆盖后续 `begin_tx(mode=None)` 使用的默认事务模式。
pub fn Database::set_default_tx_mode(self : Database, mode : TxMode) -> Unit {
  self.default_tx_mode.val = mode
}

///|
/// 当前默认事务模式。
pub fn Database::default_tx_mode(self : Database) -> TxMode {
  self.default_tx_mode.val
}
