///|
async test "sync database opens offline when bootstrap is disabled" {
  let dir = @fs.tmpdir(prefix="mturso-sync-offline")
  defer @fs.rmdir(dir, recursive=true)
  let config = @mturso.SyncConfig::new(
    dir + "/local.db",
    remote_url="http://127.0.0.1:1",
    bootstrap_if_empty=false,
  )
  let db = try @mturso.SyncDatabase::open(config) catch {
    @mturso.TursoError::SyncError(kind, message) => {
      println("sync bootstrap failed (\{@debug.to_string(kind)}): \{message}")
      raise @mturso.sync_error(kind, message)
    }
    _ => fail("unexpected sync bootstrap error type")
  } noraise {
    value => value
  }
  defer db.close()
  let conn = db.connect()
  defer conn.close()

  ignore(conn.execute("create table notes(id integer primary key, body text)"))
  ignore(conn.execute("insert into notes(body) values ('offline')"))
  let rows = conn.query("select body from notes")
  defer rows.close()
  assert_true(rows.has_next())
  let body : String = rows.get_row().get(0)
  assert_true(body == "offline")
  assert_true(!rows.has_next())
}

///|
async test "sync database bootstraps remote data" {
  match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => ()
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-sync-bootstrap")
  defer @fs.rmdir(dir, recursive=true)
  let remote_path = dir + "/remote.db"
  let remote = @mturso.Database::open(remote_path)
  {
    let seed = remote.connect()
    ignore(
      seed.execute("create table notes(id integer primary key, body text)"),
    )
    ignore(seed.execute("insert into notes(body) values ('hello'), ('turso')"))
    seed.close()
  }
  remote.close()

  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(remote_path),
  )
  defer @async.protect_from_cancel(async fn() { server.stop() })
  let config = @mturso.SyncConfig::new(
    dir + "/local.db",
    remote_url=server.base_url(),
  )
  let db = try @mturso.SyncDatabase::open(config) catch {
    @mturso.TursoError::SyncError(kind, message) => {
      println(
        "remote sync bootstrap failed (\{@debug.to_string(kind)}): \{message}",
      )
      raise @mturso.sync_error(kind, message)
    }
    _ => fail("unexpected remote sync bootstrap error type")
  } noraise {
    value => value
  }
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  let rows = conn.query("select body from notes order by id")
  defer rows.close()
  assert_true(rows.has_next())
  let first : String = rows.get_row().get(0)
  assert_true(first == "hello")
  assert_true(rows.has_next())
  let second : String = rows.get_row().get(0)
  assert_true(second == "turso")
  assert_true(!rows.has_next())

  ignore(conn.execute("begin"))
  ignore(conn.execute("insert into notes(body) values ('local')"))
  ignore(conn.execute("commit"))
  let all : Array[(Int, String)] = conn.fetch(
    "select id, body from notes order by id",
  )
  assert_true(all.length() == 3)
  assert_true(all[2].1 == "local")
}

///|
async test "sync database rejects an invalid remote URL" {
  let dir = @fs.tmpdir(prefix="mturso-sync-invalid-url")
  defer @fs.rmdir(dir, recursive=true)
  let config = @mturso.SyncConfig::new(
    dir + "/local.db",
    remote_url="not-a-url",
  )
  let mut rejected = false
  try ignore(@mturso.SyncDatabase::open(config)) catch {
    @mturso.TursoError::SyncError(@mturso.SyncErrorKind::Protocol, message) => {
      assert_true(message.contains("remote_url"))
      rejected = true
    }
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(rejected)
}

///|
async test "sync database reports network failure during bootstrap" {
  let dir = @fs.tmpdir(prefix="mturso-sync-network-error")
  defer @fs.rmdir(dir, recursive=true)
  let config = @mturso.SyncConfig::new(
    dir + "/local.db",
    remote_url="http://127.0.0.1:1",
  )
  let mut rejected = false
  try ignore(@mturso.SyncDatabase::open(config)) catch {
    @mturso.TursoError::SyncError(@mturso.SyncErrorKind::Network, message) => {
      assert_true(message.length() > 0)
      rejected = true
    }
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(rejected)
}
