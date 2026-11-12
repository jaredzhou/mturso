// Sync database facade and MoonBit-owned I/O driver for Turso's sync engine.

///|
/// Configuration for a local sync database.
pub struct SyncConfig {
  priv path : String
  priv remote_url : String
  priv auth_token : String?
  priv client_name : String
  priv long_poll_timeout_ms : Int
  priv bootstrap_if_empty : Bool
  priv max_conns : Int
}

///|
pub fn SyncConfig::new(
  path : String,
  remote_url~ : String,
  auth_token~ : String? = None,
  client_name~ : String? = None,
  long_poll_timeout_ms~ : Int = 30_000,
  bootstrap_if_empty~ : Bool = true,
  max_conns~ : Int = 4,
) -> SyncConfig {
  {
    path,
    remote_url,
    auth_token,
    client_name: match client_name {
      Some(name) if name != "" => name
      _ => "mturso-sync"
    },
    long_poll_timeout_ms,
    bootstrap_if_empty,
    max_conns,
  }
}

///|
/// A local database synchronized with a remote Turso database.
pub struct SyncDatabase {
  priv raw : @ffi.SyncDb
  priv config : SyncConfig
  priv idle : Array[@ffi.Conn]
  priv idle_len : Ref[Int]
  priv busy : Array[@ffi.Conn?]
  priv sem : @async.Semaphore
  priv operation_lock : @async.Semaphore
  priv closed : Ref[Bool]
}

///|
priv struct SyncIoContext {
  raw_db : @ffi.SyncDb
  base_url : String
  auth_token : String?
}

///|
fn check_sync_error() -> Unit raise TursoError {
  let msg = @utf8.decode_lossy(@ffi.last_error())
  if msg == "" {
    return
  }
  let kind = match @ffi.last_error_kind() {
    5 => SyncErrorKind::Network
    6 => SyncErrorKind::Auth
    7 => SyncErrorKind::Protocol
    8 => SyncErrorKind::RemoteBusy
    9 => SyncErrorKind::RemoteConflict
    10 => SyncErrorKind::Internal
    _ => raise kind_to_error(@ffi.last_error_kind(), msg)
  }
  raise TursoError::SyncError(kind, msg)
}

///|
fn normalize_remote_url(url : String) -> String raise TursoError {
  if url.has_prefix("libsql://") {
    return "https://" + url[9:].to_owned()
  }
  if url.has_prefix("turso://") {
    return "https://" + url[8:].to_owned()
  }
  if url.has_prefix("http://") || url.has_prefix("https://") {
    return url
  }
  raise TursoError::SyncError(
    SyncErrorKind::Protocol,
    "remote_url must start with http://, https://, libsql://, or turso://",
  )
}

///|
fn trim_trailing_slashes(url : String) -> String {
  let mut end = url.length()
  while end > 0 && url[end - 1] == '/' {
    end = end - 1
  }
  url[:end].to_owned()
}

///|
fn join_remote_url(base_url : String, path : String) -> String {
  if path == "" {
    return base_url
  }
  if path.has_prefix("/") {
    base_url + path
  } else {
    base_url + "/" + path
  }
}

///|
fn path_parent(path : String) -> String? {
  let mut found = None
  for i in 0..<path.length() {
    if path[i] == '/' || path[i] == '\\' {
      found = Some(i)
    }
  }
  match found {
    Some(0) => Some(path[:1].to_owned())
    Some(i) => Some(path[:i].to_owned())
    None => None
  }
}

///|
fn sync_http_method(method_name : String) -> @http.RequestMethod {
  match method_name {
    "GET" => @http.Get
    "HEAD" => @http.Head
    "POST" => @http.Post
    "PUT" => @http.Put
    "DELETE" => @http.Delete
    "CONNECT" => @http.Connect
    "OPTIONS" => @http.Options
    "TRACE" => @http.Trace
    "PATCH" => @http.Patch
    _ => @http.Extension(method_name)
  }
}

///|
fn sync_io_result(status : Int, operation : String) -> Unit raise TursoError {
  if status != 0 {
    check_sync_error()
    raise TursoError::SyncError(
      SyncErrorKind::Internal,
      "\{operation} failed with status \{status}",
    )
  }
}

///|
async fn SyncIoContext::handle_http(
  self : SyncIoContext,
  item : @ffi.SyncIo,
) -> Unit raise TursoError {
  let request_url = @utf8.decode_lossy(@ffi.sync_io_http_url(item))
  check_sync_error()
  let method_name = @utf8.decode_lossy(@ffi.sync_io_http_method(item))
  check_sync_error()
  let path = @utf8.decode_lossy(@ffi.sync_io_http_path(item))
  check_sync_error()
  let body = @ffi.sync_io_http_body(item)
  check_sync_error()
  let header_count = @ffi.sync_io_http_header_count(item)
  check_sync_error()
  let headers : @http.Headers = Map([])
  for i in 0..<header_count {
    let key = @utf8.decode_lossy(@ffi.sync_io_http_header_key(item, i))
    check_sync_error()
    let value = @utf8.decode_lossy(@ffi.sync_io_http_header_value(item, i))
    check_sync_error()
    if key != "" {
      headers[@http.CaseInsensitiveString(key)] = value
    }
  }
  if self.auth_token is Some(token) && token != "" {
    headers[@http.CaseInsensitiveString("Authorization")] = "Bearer \{token}"
  }
  if body.length() > 0 {
    headers[@http.CaseInsensitiveString("Content-Length")] = body
      .length()
      .to_string()
  }
  let url = if path != "" {
    join_remote_url(self.base_url, path)
  } else {
    request_url
  }
  let response = try {
    let client = @http.Client::Client()
    defer client.close()
    let conn = client.request(
      sync_http_method(method_name),
      url,
      extra_headers=headers,
    )
    defer conn.close()
    conn.write(body)
    let header = conn.end_request()
    let response_body = conn.read_all()
    (header, response_body)
  } catch {
    error => {
      let message = "\{error}"
      ignore(@ffi.sync_io_poison(item, @utf8.encode(message)))
      ignore(@ffi.sync_io_done(item))
      let kind = if message.contains("UnsupportedProtocol") ||
        message.contains("InvalidFormat") {
        SyncErrorKind::Protocol
      } else {
        SyncErrorKind::Network
      }
      raise TursoError::SyncError(kind, message)
    }
  } noraise {
    value => value
  }
  let (response_header, response_body) = response
  sync_io_result(
    @ffi.sync_io_status(item, response_header.code),
    "set HTTP status",
  )
  sync_io_result(
    @ffi.sync_io_push_buffer(item, response_body),
    "push HTTP body",
  )
  sync_io_result(@ffi.sync_io_done(item), "complete HTTP request")
  if response_header.code == 401 || response_header.code == 403 {
    raise TursoError::SyncError(
      SyncErrorKind::Auth,
      "sync server rejected authentication with HTTP \{response_header.code}",
    )
  }
}

///|
async fn SyncIoContext::handle_full_read(
  _self : SyncIoContext,
  item : @ffi.SyncIo,
) -> Unit raise TursoError {
  let path = @utf8.decode_lossy(@ffi.sync_io_full_read_path(item))
  check_sync_error()
  let exists = try @fs.exists(path) catch {
    error => raise TursoError::SyncError(SyncErrorKind::Internal, "\{error}")
  } noraise {
    value => value
  }
  if exists {
    let content = try @fs.read_binary(path) catch {
      error => {
        let message = "\{error}"
        ignore(@ffi.sync_io_poison(item, @utf8.encode(message)))
        ignore(@ffi.sync_io_done(item))
        raise TursoError::SyncError(SyncErrorKind::Internal, message)
      }
    } noraise {
      value => value
    }
    sync_io_result(
      @ffi.sync_io_push_buffer(item, content),
      "push full-read content",
    )
  }
  sync_io_result(@ffi.sync_io_done(item), "complete full-read request")
}

///|
async fn SyncIoContext::handle_full_write(
  _self : SyncIoContext,
  item : @ffi.SyncIo,
) -> Unit raise TursoError {
  let path = @utf8.decode_lossy(@ffi.sync_io_full_write_path(item))
  check_sync_error()
  let content = @ffi.sync_io_full_write_content(item)
  check_sync_error()
  let temp = path + ".mturso.tmp"
  try {
    match path_parent(path) {
      Some(parent) => @fs.mkdir(parent, recursive=true, allow_exist=true)
      None => ()
    }
    @fs.write_binary(temp, content)
    @fs.rename(temp, path, replace=true)
  } catch {
    error => {
      let message = "\{error}"
      try ignore(@fs.remove(temp, allow_missing=true)) catch {
        _ => ()
      } noraise {
        _ => ()
      }
      ignore(@ffi.sync_io_poison(item, @utf8.encode(message)))
      ignore(@ffi.sync_io_done(item))
      raise TursoError::SyncError(SyncErrorKind::Internal, message)
    }
  } noraise {
    _ => ()
  }
  sync_io_result(@ffi.sync_io_done(item), "complete full-write request")
}

///|
async fn SyncIoContext::handle_item(
  self : SyncIoContext,
  item : @ffi.SyncIo,
) -> Unit raise TursoError {
  match @ffi.sync_io_kind(item) {
    1 => self.handle_http(item)
    2 => self.handle_full_read(item)
    3 => self.handle_full_write(item)
    0 => sync_io_result(@ffi.sync_io_done(item), "complete empty IO request")
    kind =>
      raise TursoError::SyncError(
        SyncErrorKind::Protocol,
        "unknown sync I/O request kind \{kind}",
      )
  }
}

///|
fn SyncIoContext::step_callbacks(self : SyncIoContext) -> Unit raise TursoError {
  sync_io_result(
    @ffi.sync_db_step_callbacks(self.raw_db),
    "run sync I/O callbacks",
  )
}

///|
async fn SyncIoContext::process_item(
  self : SyncIoContext,
  item : @ffi.SyncIo,
) -> Unit raise TursoError {
  defer @ffi.sync_io_close(item)
  self.handle_item(item)
}

///|
async fn SyncIoContext::process_one(
  self : SyncIoContext,
) -> Unit raise TursoError {
  let item = @ffi.sync_db_take_io(self.raw_db)
  check_sync_error()
  if !@ffi.sync_io_is_null(item) {
    self.process_item(item)
  } else {
    @ffi.sync_io_close(item)
  }
  self.step_callbacks()
}

///|
async fn SyncIoContext::process_queue(
  self : SyncIoContext,
) -> Unit raise TursoError {
  for ;; {
    let item = @ffi.sync_db_take_io(self.raw_db)
    check_sync_error()
    if @ffi.sync_io_is_null(item) {
      @ffi.sync_io_close(item)
      break
    }
    self.process_item(item)
  }
  self.step_callbacks()
}

///|
async fn drive_sync_operation(
  io : SyncIoContext,
  op : @ffi.SyncOp,
) -> Unit raise TursoError {
  for ;; {
    match @ffi.sync_op_resume(op) {
      0 => continue
      3 => {
        io.process_queue()
        continue
      }
      1 => return
      _ => {
        check_sync_error()
        raise TursoError::SyncError(
          SyncErrorKind::Internal,
          "sync operation failed without an error message",
        )
      }
    }
  }
}

///|
/// Open a sync database and bootstrap it when configured.
pub async fn SyncDatabase::open(
  config : SyncConfig,
) -> SyncDatabase raise TursoError {
  if config.path == "" {
    raise TursoError::SyncError(
      SyncErrorKind::Protocol,
      "path must not be empty",
    )
  }
  if config.long_poll_timeout_ms < 0 {
    raise TursoError::SyncError(
      SyncErrorKind::Protocol,
      "long_poll_timeout_ms must be non-negative",
    )
  }
  let remote_url = normalize_remote_url(config.remote_url)
  let raw = @ffi.sync_db_new(
    @utf8.encode(config.path),
    @utf8.encode(remote_url),
    @utf8.encode(config.client_name),
    config.long_poll_timeout_ms,
    config.bootstrap_if_empty,
  )
  check_sync_error()
  let n = if config.max_conns <= 0 { 1 } else { config.max_conns }
  let db = {
    raw,
    config: {
      path: config.path,
      remote_url,
      auth_token: config.auth_token,
      client_name: config.client_name,
      long_poll_timeout_ms: config.long_poll_timeout_ms,
      bootstrap_if_empty: config.bootstrap_if_empty,
      max_conns: n,
    },
    idle: [],
    idle_len: Ref(0),
    busy: [],
    sem: @async.Semaphore::Semaphore(n),
    operation_lock: @async.Semaphore::Semaphore(1),
    closed: Ref(false),
  }
  errdefer db.close()
  let io : SyncIoContext = {
    raw_db: raw,
    base_url: trim_trailing_slashes(remote_url),
    auth_token: db.config.auth_token,
  }
  let op = @ffi.sync_db_create(raw)
  check_sync_error()
  defer @ffi.sync_op_close(op)
  drive_sync_operation(io, op)
  db
}

///|
fn SyncDatabase::release_connection(
  self : SyncDatabase,
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
/// Borrow a connection from the sync database.
pub async fn SyncDatabase::connect(
  self : SyncDatabase,
) -> Connection raise TursoError {
  if self.closed.val {
    raise TursoError::ConnectionError("sync database is closed")
  }
  self.sem.acquire()
  errdefer self.sem.release()
  let raw = if self.idle_len.val > 0 {
    self.idle_len.val = self.idle_len.val - 1
    self.idle[self.idle_len.val]
  } else {
    let op = @ffi.sync_db_connect(self.raw)
    defer @ffi.sync_op_close(op)
    check_sync_error()
    let io : SyncIoContext = {
      raw_db: self.raw,
      base_url: trim_trailing_slashes(self.config.remote_url),
      auth_token: self.config.auth_token,
    }
    drive_sync_operation(io, op)
    if @ffi.sync_op_result_kind(op) != 1 {
      raise TursoError::SyncError(
        SyncErrorKind::Protocol,
        "sync connect returned an unexpected result",
      )
    }
    let conn = @ffi.sync_op_extract_connection(op, self.raw)
    check_sync_error()
    conn
  }
  let idx = self.busy.length()
  self.busy.push(Some(raw))
  {
    raw,
    lifetime: {
      release: () => self.release_connection(raw, idx),
      is_closed: () => self.closed.val,
      default_tx_mode: () => TxMode::Deferred,
    },
    closed: Ref(false),
    sync_io: Some({
      raw_db: self.raw,
      base_url: trim_trailing_slashes(self.config.remote_url),
      auth_token: self.config.auth_token,
    }),
  }
}

///|
/// Push committed local changes to the remote database.
pub async fn SyncDatabase::push(self : SyncDatabase) -> Unit raise TursoError {
  if self.closed.val {
    raise TursoError::ConnectionError("sync database is closed")
  }
  self.operation_lock.acquire()
  defer self.operation_lock.release()
  let io : SyncIoContext = {
    raw_db: self.raw,
    base_url: trim_trailing_slashes(self.config.remote_url),
    auth_token: self.config.auth_token,
  }
  let op = @ffi.sync_db_push(self.raw)
  defer @ffi.sync_op_close(op)
  check_sync_error()
  drive_sync_operation(io, op)
}

///|
/// Close the sync database and every pooled connection it owns.
pub fn SyncDatabase::close(self : SyncDatabase) -> Unit {
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
  @ffi.sync_db_close(self.raw)
}

///|
pub fn SyncDatabase::is_closed(self : SyncDatabase) -> Bool {
  self.closed.val
}
