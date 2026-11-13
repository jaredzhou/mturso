// Durable page-revision journal for the native sync server.

///|
const SYNC_STATE_DIR_SUFFIX : String = ".mturso-sync"

///|
const SYNC_STATE_FILE : String = "state"

///|
const SYNC_BASELINE_FILE : String = "baseline.db"

///|
const SYNC_REVISIONS_DIR : String = "revisions"

///|
const SYNC_DELTA_HEADER_SIZE : Int = 12

///|
const SYNC_DELTA_RECORD_SIZE : Int = 4 + SYNC_PAGE_SIZE

///|
const SYNC_DELTA_MAGIC_0 : Byte = b'M'

///|
const SYNC_DELTA_MAGIC_1 : Byte = b'T'

///|
const SYNC_DELTA_MAGIC_2 : Byte = b'S'

///|
const SYNC_DELTA_MAGIC_3 : Byte = b'Y'

///|
const SYNC_DELTA_MAGIC_4 : Byte = b'N'

///|
const SYNC_DELTA_MAGIC_5 : Byte = b'C'

///|
const SYNC_DELTA_MAGIC_6 : Byte = b'0'

///|
const SYNC_DELTA_MAGIC_7 : Byte = b'1'

///|
const MAX_SYNC_LONG_POLL_MS : Int = 30_000

///|
const SYNC_LONG_POLL_INTERVAL_MS : Int = 100

///|
/// Shared state for `/pull-updates`; one instance is stored in the router.
pub struct NativeSyncState {
  priv db : @mturso.Database
  priv database_path : String
  priv root : String
  priv operation_lock : @async.Semaphore
}

///|
priv struct SyncSnapshot {
  revision : Int64
  contents : Bytes
  page_count : Int
}

///|
pub fn NativeSyncState::new(
  db : @mturso.Database,
  database_path : String,
) -> NativeSyncState {
  {
    db,
    database_path,
    root: database_path + SYNC_STATE_DIR_SUFFIX,
    operation_lock: @async.Semaphore::Semaphore(1),
  }
}

///|
fn sync_delta_path(root : String, revision : Int64) -> String {
  root +
  "/" +
  SYNC_REVISIONS_DIR +
  "/" +
  revision.to_string() +
  ".delta"
}

///|
async fn write_atomic(path : String, contents : Bytes) -> Unit raise {
  let temp = path + ".tmp"
  @fs.write_binary(temp, contents)
  @fs.rename(temp, path, replace=true)
}

///|
async fn ensure_sync_directories(root : String) -> Unit raise {
  if !@fs.exists(root) {
    @fs.mkdir(root, recursive=true)
  }
  let revisions = root + "/" + SYNC_REVISIONS_DIR
  if !@fs.exists(revisions) {
    @fs.mkdir(revisions, recursive=true)
  }
}

///|
fn snapshot_hash(contents : Bytes) -> UInt64 {
  let mut hash = 14695981039346656037UL
  for byte in contents {
    hash = (hash ^ byte.to_uint64()) * 1099511628211UL
  }
  hash
}

///|
fn page_bytes(contents : Bytes, page_id : Int) -> Bytes {
  let start = page_id * SYNC_PAGE_SIZE
  @buffer.from_bytes(contents[start:start + SYNC_PAGE_SIZE]).to_bytes()
}

///|
fn pages_equal(
  left : Bytes,
  left_page : Int,
  right : Bytes,
  right_page : Int,
) -> Bool {
  let left_start = left_page * SYNC_PAGE_SIZE
  let right_start = right_page * SYNC_PAGE_SIZE
  for offset in 0..<SYNC_PAGE_SIZE {
    if left[left_start + offset] != right[right_start + offset] {
      return false
    }
  }
  true
}

///|
fn changed_page_ids(previous : Bytes, current : Bytes) -> Array[Int] {
  if snapshot_hash(previous) == snapshot_hash(current) {
    return []
  }
  let previous_pages = previous.length() / SYNC_PAGE_SIZE
  let current_pages = current.length() / SYNC_PAGE_SIZE
  let changed = []
  for page_id in 0..<current_pages {
    if page_id >= previous_pages ||
      !pages_equal(previous, page_id, current, page_id) {
      changed.push(page_id)
    }
  }
  changed
}

///|
fn encode_delta(contents : Bytes, changed_pages : Array[Int]) -> Bytes {
  let output = Buffer(
    size_hint=SYNC_DELTA_HEADER_SIZE +
      changed_pages.length() *
      SYNC_DELTA_RECORD_SIZE,
  )
  output.write_byte(SYNC_DELTA_MAGIC_0)
  output.write_byte(SYNC_DELTA_MAGIC_1)
  output.write_byte(SYNC_DELTA_MAGIC_2)
  output.write_byte(SYNC_DELTA_MAGIC_3)
  output.write_byte(SYNC_DELTA_MAGIC_4)
  output.write_byte(SYNC_DELTA_MAGIC_5)
  output.write_byte(SYNC_DELTA_MAGIC_6)
  output.write_byte(SYNC_DELTA_MAGIC_7)
  output.write_uint_le(changed_pages.length().reinterpret_as_uint())
  for page_id in changed_pages {
    output.write_uint_le(page_id.reinterpret_as_uint())
    output.write_bytes(page_bytes(contents, page_id))
  }
  output.to_bytes()
}

///|
fn delta_magic_is_valid(data : Bytes) -> Bool {
  data.length() >= SYNC_DELTA_HEADER_SIZE &&
  data[0] == SYNC_DELTA_MAGIC_0 &&
  data[1] == SYNC_DELTA_MAGIC_1 &&
  data[2] == SYNC_DELTA_MAGIC_2 &&
  data[3] == SYNC_DELTA_MAGIC_3 &&
  data[4] == SYNC_DELTA_MAGIC_4 &&
  data[5] == SYNC_DELTA_MAGIC_5 &&
  data[6] == SYNC_DELTA_MAGIC_6 &&
  data[7] == SYNC_DELTA_MAGIC_7
}

///|
fn read_uint_le(data : Bytes, offset : Int) -> UInt {
  data[offset].to_uint() |
  (data[offset + 1].to_uint() << 8) |
  (data[offset + 2].to_uint() << 16) |
  (data[offset + 3].to_uint() << 24)
}

///|
fn decode_delta(data : Bytes) -> Array[(Int, Bytes)] raise {
  if !delta_magic_is_valid(data) {
    raise Failure::Failure("invalid sync delta header")
  }
  let page_count = read_uint_le(data, 8).reinterpret_as_int()
  let expected = SYNC_DELTA_HEADER_SIZE +
    page_count *
    SYNC_DELTA_RECORD_SIZE
  if data.length() != expected {
    raise Failure::Failure(
      "invalid sync delta length: expected \{expected}, got \{data.length()}",
    )
  }
  let pages = []
  for index in 0..<page_count {
    let offset = SYNC_DELTA_HEADER_SIZE + index * SYNC_DELTA_RECORD_SIZE
    let page_id = read_uint_le(data, offset).reinterpret_as_int()
    let page = @buffer.from_bytes(
      data[offset + 4:offset + 4 + SYNC_PAGE_SIZE],
    ).to_bytes()
    pages.push((page_id, page))
  }
  pages
}

///|
async fn write_delta(
  root : String,
  revision : Int64,
  contents : Bytes,
  changed_pages : Array[Int],
) -> Unit raise {
  write_atomic(
    sync_delta_path(root, revision),
    encode_delta(contents, changed_pages),
  )
}

///|
async fn checkpoint_database(db : @mturso.Database) -> Unit raise {
  let conn = db.connect()
  defer conn.close()
  let rows = conn.query("pragma wal_checkpoint(truncate)")
  defer rows.close()
  while rows.has_next() {
    ignore(rows.get_row())
  }
}

///|
async fn NativeSyncState::current_snapshot(
  self : NativeSyncState,
) -> SyncSnapshot raise {
  try checkpoint_database(self.db) catch {
    error =>
      raise Failure::Failure(
        "failed to checkpoint database for pull-updates: \{error}",
      )
  } noraise {
    _ => ()
  }
  let contents = try @fs.read_binary(self.database_path) catch {
    error =>
      raise Failure::Failure("failed to read database snapshot: \{error}")
  } noraise {
    value => value
  }
  if contents.length() % SYNC_PAGE_SIZE != 0 {
    raise Failure::Failure(
      "database size \{contents.length()} is not a multiple of \{SYNC_PAGE_SIZE}",
    )
  }
  let page_count = contents.length() / SYNC_PAGE_SIZE
  ensure_sync_directories(self.root)
  let state_path = self.root + "/" + SYNC_STATE_FILE
  let baseline_path = self.root + "/" + SYNC_BASELINE_FILE
  if !@fs.exists(state_path) || !@fs.exists(baseline_path) {
    let previous_revision = if @fs.exists(state_path) {
      let raw = @fs.read_text(state_path)
      let parsed = try @string.parse_int64(raw.trim()) catch {
        _ => 0L
      } noraise {
        value => value
      }
      if parsed < 0L { 0L } else { parsed }
    } else {
      0L
    }
    let revision = previous_revision + 1L
    let all_pages = []
    for page_id in 0..<page_count {
      all_pages.push(page_id)
    }
    write_delta(self.root, revision, contents, all_pages)
    write_atomic(state_path, @utf8.encode(revision.to_string()))
    write_atomic(baseline_path, contents)
    return { revision, contents, page_count }
  }
  let previous = try @fs.read_binary(baseline_path) catch {
    error => raise Failure::Failure("failed to read sync baseline: \{error}")
  } noraise {
    value => value
  }
  if previous.length() % SYNC_PAGE_SIZE != 0 {
    raise Failure::Failure(
      "sync baseline size \{previous.length()} is not a multiple of \{SYNC_PAGE_SIZE}",
    )
  }
  let raw_revision = @fs.read_text(state_path)
  let previous_revision = try @string.parse_int64(raw_revision.trim()) catch {
    _ =>
      raise Failure::Failure(
        "invalid sync state revision: \{raw_revision.trim()}",
      )
  } noraise {
    value => value
  }
  if previous_revision <= 0L {
    raise Failure::Failure(
      "invalid sync state revision: \{previous_revision}",
    )
  }
  if snapshot_hash(previous) == snapshot_hash(contents) {
    return { revision: previous_revision, contents, page_count }
  }
  let revision = previous_revision + 1L
  let changed_pages = changed_page_ids(previous, contents)
  write_delta(self.root, revision, contents, changed_pages)
  write_atomic(state_path, @utf8.encode(revision.to_string()))
  write_atomic(baseline_path, contents)
  { revision, contents, page_count }
}

///|
async fn NativeSyncState::pages_since(
  self : NativeSyncState,
  from_revision : Int64,
  to_revision : Int64,
  page_count : Int,
) -> Array[(Int, Bytes)] raise {
  let latest = Map([])
  let mut revision = from_revision + 1L
  while revision <= to_revision {
    let path = sync_delta_path(self.root, revision)
    if !@fs.exists(path) {
      raise Failure::Failure(
        "expired client revision: missing delta for \{revision}",
      )
    }
    let delta = try @fs.read_binary(path) catch {
      error =>
        raise Failure::Failure(
          "failed to read sync delta \{revision}: \{error}",
        )
    } noraise {
      value => value
    }
    for entry in decode_delta(delta) {
      latest[entry.0] = entry.1
    }
    revision = revision + 1L
  }
  let pages = []
  for page_id in 0..<page_count {
    match latest.get(page_id) {
      Some(page) => pages.push((page_id, page))
      None => ()
    }
  }
  pages
}

///|
fn all_pages(contents : Bytes) -> Array[(Int, Bytes)] {
  let pages = []
  for page_id in 0..<(contents.length() / SYNC_PAGE_SIZE) {
    pages.push((page_id, page_bytes(contents, page_id)))
  }
  pages
}

///|
priv enum SyncClientRevision {
  FullBase
  Since(Int64)
}

///|
fn parse_client_revision(revision : String) -> SyncClientRevision raise {
  if revision == "" || revision == "0" || revision.has_prefix("page-v1:") ||
    revision.has_prefix("g1:o") {
    return SyncClientRevision::FullBase
  }
  if revision.has_prefix("g1:r") {
    let raw = revision[4:].to_owned()
    let value = try @string.parse_int64(raw) catch {
      _ =>
        raise Failure::Failure(
          "invalid pull-updates client revision: \{revision}",
        )
    } noraise {
      value => value
    }
    if value <= 0L {
      raise Failure::Failure(
        "invalid pull-updates client revision: \{revision}",
      )
    }
    return SyncClientRevision::Since(value)
  }
  if revision.has_prefix("g") && revision.contains(":") {
    raise Failure::Failure(
      "unsupported pull-updates revision generation: \{revision}",
    )
  }
  raise Failure::Failure(
    "invalid pull-updates client revision: \{revision}",
  )
}

///|
fn sync_revision(revision : Int64) -> String {
  "g1:r\{revision}"
}
