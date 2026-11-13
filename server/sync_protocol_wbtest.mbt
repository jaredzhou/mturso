///|
fn pull_request(
  client_revision : String,
  stream_kind~ : UInt32 = 0U,
  encoding~ : UInt32 = 0U,
) -> Bytes raise {
  let output = Buffer()
  if encoding != 0U {
    output |> @protobuf.write_varint(8UL)
    output |> @protobuf.write_uint32(encoding)
  }
  if client_revision != "" {
    output |> @protobuf.write_varint(26UL)
    output |> @protobuf.write_string(client_revision)
  }
  if stream_kind != 0U {
    output |> @protobuf.write_varint(64UL)
    output |> @protobuf.write_uint32(stream_kind)
  }
  output.to_bytes()
}

///|
async test "native pull rejects invalid revisions and stream kinds" {
  let dir = @fs.tmpdir(prefix="mturso-pull-errors")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/remote.db"
  let db = @mturso.Database::open(path)
  defer db.close()
  let state = NativeSyncState::new(db, path)

  let initial = state.pull(pull_request(""))
  assert_true(initial.status == 200)

  let cases = [
    (pull_request("not-a-revision"), "invalid pull-updates client revision"),
    (pull_request("g2:r1"), "unsupported pull-updates revision generation"),
    (pull_request("g1:r2"), "client revision is from the future"),
    (pull_request("", stream_kind=99U), "unknown pull-updates stream kind"),
    (pull_request("", encoding=1U), "zstd page encoding"),
  ]
  for entry in cases {
    let response = state.pull(entry.0)
    assert_true(response.status == 400)
    assert_true(@utf8.decode_lossy(response.body).contains(entry.1))
  }
}

///|
async test "native pull accepts the MVCC page fallback path" {
  let dir = @fs.tmpdir(prefix="mturso-pull-mvcc-fallback")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/remote.db"
  let db = @mturso.Database::open(path)
  defer db.close()
  let conn = db.connect()
  ignore(conn.execute("create table notes(id integer primary key, body text)"))
  ignore(conn.execute("insert into notes(body) values ('fallback')"))
  conn.close()

  let state = NativeSyncState::new(db, path)
  let response = state.pull(pull_request("", stream_kind=1U))
  assert_true(response.status == 200)
  assert_true(response.content_type == "application/protobuf")
  assert_true(response.body.length() > 0)
}
