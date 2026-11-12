// Turso v0.8.2 sync protocol subset used by initial page bootstrap.

///|
const SYNC_PAGE_SIZE : Int = 4096

///|
const PULL_PAGES : UInt32 = 0

///|
const PULL_MVCC_LOGICAL_LOG : UInt32 = 1

///|
const PAGE_ENCODING_RAW : UInt32 = 0

///|
const PAGE_ENCODING_ZSTD : UInt32 = 1

///|
const APPLY_INCREMENTAL : UInt32 = 0

///|
const APPLY_REPLACE_BASE : UInt32 = 1

///|
const PROTOCOL_PAGES : UInt32 = 1

///|
/// Binary response used by `/pull-updates`.
pub(all) struct NativeBinaryHttpResponse {
  status : Int
  content_type : String
  body : Bytes
}

///|
priv struct PullUpdatesRequest {
  mut encoding : UInt32
  mut stream_kind : UInt32
  mut client_revision : String
  mut server_pages_selector : Bytes
  mut server_query_selector : String
}

///|
impl Default for PullUpdatesRequest with fn default() -> PullUpdatesRequest {
  {
    encoding: PAGE_ENCODING_RAW,
    stream_kind: PULL_PAGES,
    client_revision: "",
    server_pages_selector: b"",
    server_query_selector: "",
  }
}

///|
impl @protobuf.Read for PullUpdatesRequest with fn read_with_limit(
  reader : @protobuf.LimitedReader[&@protobuf.Reader],
) -> PullUpdatesRequest raise {
  let request : PullUpdatesRequest = Default::default()
  while (reader |> @protobuf.read_next_message_field())
        is Some((field_number, wire)) {
    match (field_number, wire) {
      (1, _) => request.encoding = (reader |> @protobuf.read_enum()).0
      (2, _) => reader |> @protobuf.read_string() |> ignore
      (3, _) => request.client_revision = reader |> @protobuf.read_string()
      (4, _) => reader |> @protobuf.read_uint32() |> ignore
      (5, _) => request.server_pages_selector = reader |> @protobuf.read_bytes()
      (6, _) => reader |> @protobuf.read_bytes() |> ignore
      (7, _) =>
        request.server_query_selector = reader |> @protobuf.read_string()
      (8, _) => request.stream_kind = (reader |> @protobuf.read_enum()).0
      _ => reader |> @protobuf.skip_message_field_by_number(field_number, wire)
    }
  }
  request
}

///|
priv struct PullUpdatesResponseHeader {
  server_revision : String
  db_size : UInt64
  raw_encoding : Bool
  stream_kind : UInt32
  apply_mode : UInt32
  protocol : UInt32
}

///|
impl @protobuf.Write for PullUpdatesResponseHeader with fn write(
  self : PullUpdatesResponseHeader,
  writer : &@protobuf.Writer,
) -> Unit raise {
  if self.server_revision != "" {
    writer |> @protobuf.write_varint(10UL)
    writer |> @protobuf.write_string(self.server_revision)
  }
  if self.db_size != 0UL {
    writer |> @protobuf.write_varint(16UL)
    writer |> @protobuf.write_uint64(self.db_size)
  }
  if self.raw_encoding {
    writer |> @protobuf.write_varint(26UL)
    writer |> @protobuf.write_varint(0UL)
  }
  if self.stream_kind != 0U {
    writer |> @protobuf.write_varint(40UL)
    writer |> @protobuf.write_uint32(self.stream_kind)
  }
  if self.apply_mode != 0U {
    writer |> @protobuf.write_varint(48UL)
    writer |> @protobuf.write_uint32(self.apply_mode)
  }
  if self.protocol != 0U {
    writer |> @protobuf.write_varint(64UL)
    writer |> @protobuf.write_uint32(self.protocol)
  }
}

///|
priv struct PageData {
  page_id : UInt64
  encoded_page : Bytes
}

///|
impl @protobuf.Write for PageData with fn write(
  self : PageData,
  writer : &@protobuf.Writer,
) -> Unit raise {
  if self.page_id != 0UL {
    writer |> @protobuf.write_varint(8UL)
    writer |> @protobuf.write_uint64(self.page_id)
  }
  if self.encoded_page.length() != 0 {
    writer |> @protobuf.write_varint(18UL)
    writer |> @protobuf.write_bytes(self.encoded_page)
  }
}

///|
fn pull_updates_error(
  status : Int,
  message : String,
) -> NativeBinaryHttpResponse {
  {
    status,
    content_type: "application/json",
    body: @utf8.encode(error_response(status, message).stringify()),
  }
}

///|
fn[M : @protobuf.Write] write_framed(
  output : @buffer.Buffer,
  message : M,
) -> Unit raise {
  let payload = Buffer()
  message.write(payload)
  output |> @protobuf.write_varint(payload.length().to_uint64())
  output.write_bytes(payload.to_bytes())
}

///|
fn page_revision(contents : Bytes) -> String {
  let mut hash = 14695981039346656037UL
  for byte in contents {
    hash = (hash ^ byte.to_uint64()) * 1099511628211UL
  }
  "page-v1:\{contents.length()}:\{hash}"
}

///|
async fn checkpoint_database(db : @mturso.Database) -> Unit {
  let conn = db.connect()
  defer conn.close()
  let rows = conn.query("pragma wal_checkpoint(truncate)")
  defer rows.close()
  while rows.has_next() {
    ignore(rows.get_row())
  }
}

///|
/// Handle one v0.8.2 `/pull-updates` request with a durable full-page snapshot.
pub async fn process_pull_updates_request(
  db : @mturso.Database,
  database_path : String,
  body : Bytes,
) -> NativeBinaryHttpResponse {
  if database_path == ":memory:" {
    return pull_updates_error(
      400, "pull-updates requires a file-backed database",
    )
  }
  let reader = @protobuf.BytesReader::from_bytes(body)
  let request : PullUpdatesRequest = try
    @protobuf.Read::read(reader as &@protobuf.Reader)
  catch {
    error =>
      return pull_updates_error(400, "invalid pull-updates request: \{error}")
  } noraise {
    value => value
  }
  if request.encoding == PAGE_ENCODING_ZSTD {
    return pull_updates_error(400, "zstd page encoding is not supported")
  }
  if request.encoding != PAGE_ENCODING_RAW {
    return pull_updates_error(400, "unknown page encoding: \{request.encoding}")
  }
  if request.stream_kind != PULL_PAGES {
    if request.stream_kind == PULL_MVCC_LOGICAL_LOG {
      return pull_updates_error(
        501, "MVCC logical-log pull is not implemented by the native server",
      )
    }
    return pull_updates_error(
      400,
      "unknown pull-updates stream kind: \{request.stream_kind}",
    )
  }
  if request.server_pages_selector.length() != 0 ||
    request.server_query_selector != "" {
    return pull_updates_error(
      501, "partial page selectors are not implemented by the native server",
    )
  }
  try checkpoint_database(db) catch {
    error =>
      return pull_updates_error(
        500,
        "failed to checkpoint database for pull-updates: \{error}",
      )
  } noraise {
    _ => ()
  }
  let contents = try @fs.read_binary(database_path) catch {
    error =>
      return pull_updates_error(
        500,
        "failed to read database snapshot: \{error}",
      )
  } noraise {
    value => value
  }
  if contents.length() % SYNC_PAGE_SIZE != 0 {
    return pull_updates_error(
      500,
      "database size \{contents.length()} is not a multiple of \{SYNC_PAGE_SIZE}",
    )
  }
  let page_count = contents.length() / SYNC_PAGE_SIZE
  let revision = page_revision(contents)
  let unchanged = request.client_revision == revision
  let header : PullUpdatesResponseHeader = {
    server_revision: revision,
    db_size: page_count.to_uint64(),
    raw_encoding: true,
    stream_kind: PULL_PAGES,
    apply_mode: if unchanged {
      APPLY_INCREMENTAL
    } else {
      APPLY_REPLACE_BASE
    },
    protocol: PROTOCOL_PAGES,
  }
  let output = Buffer(size_hint=contents.length() + page_count * 32)
  try write_framed(output, header) catch {
    error =>
      return pull_updates_error(
        500,
        "failed to encode pull-updates header: \{error}",
      )
  } noraise {
    _ => ()
  }
  if unchanged {
    return {
      status: 200,
      content_type: "application/protobuf",
      body: output.to_bytes(),
    }
  }
  for page_id in 0..<page_count {
    let start = page_id * SYNC_PAGE_SIZE
    let page = @buffer.from_bytes(contents[start:start + SYNC_PAGE_SIZE]).to_bytes()
    let data : PageData = { page_id: page_id.to_uint64(), encoded_page: page, }
    try write_framed(output, data) catch {
      error =>
        return pull_updates_error(
          500,
          "failed to encode pull-updates page \{page_id}: \{error}",
        )
    } noraise {
      _ => ()
    }
  }
  {
    status: 200,
    content_type: "application/protobuf",
    body: output.to_bytes(),
  }
}
