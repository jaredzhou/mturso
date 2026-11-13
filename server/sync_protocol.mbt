// Turso v0.8.2 sync protocol subset used by initial page bootstrap.

///|
const SYNC_PAGE_SIZE : Int = 4096

///|
const PULL_PAGES : UInt = 0

///|
const PULL_MVCC_LOGICAL_LOG : UInt = 1

///|
const PAGE_ENCODING_RAW : UInt = 0

///|
const PAGE_ENCODING_ZSTD : UInt = 1

///|
const APPLY_INCREMENTAL : UInt = 0

///|
const APPLY_REPLACE_BASE : UInt = 1

///|
const PROTOCOL_PAGES : UInt = 1

///|
const PROTOCOL_MVCC_LOGICAL : UInt = 2

///|
/// Binary response used by `/pull-updates`.
pub(all) struct NativeBinaryHttpResponse {
  status : Int
  content_type : String
  body : Bytes
}

///|
priv struct PullUpdatesRequest {
  mut encoding : UInt
  mut stream_kind : UInt
  mut client_revision : String
  mut long_poll_timeout_ms : UInt
  mut server_pages_selector : Bytes
  mut server_query_selector : String
}

///|
impl Default for PullUpdatesRequest with fn default() -> PullUpdatesRequest {
  {
    encoding: PAGE_ENCODING_RAW,
    stream_kind: PULL_PAGES,
    client_revision: "",
    long_poll_timeout_ms: 0U,
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
      (4, _) => request.long_poll_timeout_ms = reader |> @protobuf.read_uint32()
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
  stream_kind : UInt
  apply_mode : UInt
  protocol : UInt
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
/// Handle one v0.8.2 `/pull-updates` request on a shared revision journal.
pub async fn NativeSyncState::pull(
  self : NativeSyncState,
  body : Bytes,
) -> NativeBinaryHttpResponse {
  if self.database_path == ":memory:" {
    return pull_updates_error(
      400, "pull-updates requires a file-backed database",
    )
  }
  let reader = @protobuf.BytesReader::from_bytes(body)
  let request : PullUpdatesRequest = @protobuf.Read::read(
    reader as &@protobuf.Reader,
  ) catch {
    error =>
      return pull_updates_error(400, "invalid pull-updates request: \{error}")
  }
  if request.encoding == PAGE_ENCODING_ZSTD {
    return pull_updates_error(400, "zstd page encoding is not supported")
  }
  if request.encoding != PAGE_ENCODING_RAW {
    return pull_updates_error(400, "unknown page encoding: \{request.encoding}")
  }
  if request.stream_kind != PULL_PAGES {
    if request.stream_kind != PULL_MVCC_LOGICAL_LOG {
      return pull_updates_error(
        400,
        "unknown pull-updates stream kind: \{request.stream_kind}",
      )
    }
  }
  if request.server_pages_selector.length() != 0 ||
    request.server_query_selector != "" {
    return pull_updates_error(
      501, "partial page selectors are not implemented by the native server",
    )
  }
  let selection = parse_client_revision(request.client_revision) catch {
    error => return pull_updates_error(400, "\{error}")
  }
  self.operation_lock.acquire()
  defer self.operation_lock.release()
  let mut current = self.current_snapshot() catch {
    error => return pull_updates_error(500, "\{error}")
  }
  match selection {
    Since(revision) =>
      if revision > current.revision {
        return pull_updates_error(
          400,
          "pull-updates client revision is from the future: \{request.client_revision}",
        )
      } else if revision == current.revision {
        let timeout = if request.long_poll_timeout_ms >
          MAX_SYNC_LONG_POLL_MS.reinterpret_as_uint() {
          MAX_SYNC_LONG_POLL_MS
        } else {
          request.long_poll_timeout_ms.reinterpret_as_int()
        }
        let deadline = @async.now() + timeout.to_int64()
        while @async.now() < deadline {
          let remaining = deadline - @async.now()
          let delay = if remaining < SYNC_LONG_POLL_INTERVAL_MS.to_int64() {
            remaining.to_int()
          } else {
            SYNC_LONG_POLL_INTERVAL_MS
          }
          if delay > 0 {
            @async.sleep(delay)
          }
          current = self.current_snapshot() catch {
            error => return pull_updates_error(500, "\{error}")
          }
          if current.revision != revision {
            break
          }
        }
      }
    FullBase => ()
  }
  let pages = try {
    match selection {
      FullBase => all_pages(current.contents)
      Since(revision) =>
        if revision >= current.revision {
          []
        } else {
          self.pages_since(revision, current.revision, current.page_count)
        }
    }
  } catch {
    error => return pull_updates_error(400, "\{error}")
  }
  let apply_mode = match selection {
    FullBase => APPLY_REPLACE_BASE
    Since(_) => APPLY_INCREMENTAL
  }
  let protocol = if request.stream_kind == PULL_MVCC_LOGICAL_LOG {
    PROTOCOL_MVCC_LOGICAL
  } else {
    PROTOCOL_PAGES
  }
  let header : PullUpdatesResponseHeader = {
    server_revision: sync_revision(current.revision),
    db_size: current.page_count.to_uint64(),
    raw_encoding: true,
    stream_kind: PULL_PAGES,
    apply_mode,
    protocol,
  }
  let mut payload_bytes = 0
  for entry in pages {
    payload_bytes = payload_bytes + entry.1.length()
  }
  let output = Buffer(size_hint=pages.length() * 32 + payload_bytes)
  write_framed(output, header) catch {
    error =>
      return pull_updates_error(
        500,
        "failed to encode pull-updates header: \{error}",
      )
  }
  for entry in pages {
    let (page_id, page) = entry
    let data : PageData = { page_id: page_id.to_uint64(), encoded_page: page, }
    write_framed(output, data) catch {
      error =>
        return pull_updates_error(
          500,
          "failed to encode pull-updates page \{page_id}: \{error}",
        )
    }
  }
  {
    status: 200,
    content_type: "application/protobuf",
    body: output.to_bytes(),
  }
}
