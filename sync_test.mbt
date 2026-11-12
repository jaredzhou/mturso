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

///|
async test "sync database pushes committed local changes" {
  match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => ()
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-sync-push")
  defer @fs.rmdir(dir, recursive=true)
  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(dir + "/remote.db"),
  )
  defer @async.protect_from_cancel(async fn() { server.stop() })

  let source = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(dir + "/source.db", remote_url=server.base_url()),
  )
  let source_conn = source.connect()
  ignore(
    source_conn.execute("create table notes(id integer primary key, body text)"),
  )
  ignore(
    source_conn.execute(
      "insert into notes(body) values ('first'), ('second'), ('delete-me')",
    ),
  )
  ignore(
    source_conn.execute(
      "update notes set body = 'updated' where body = 'first'",
    ),
  )
  ignore(source_conn.execute("delete from notes where body = 'delete-me'"))
  source.push()
  let push_failures : Ref[Int] = Ref(0)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      try source.push() catch {
        _ => push_failures.val = push_failures.val + 1
      } noraise {
        _ => ()
      }
    })
    group.spawn_bg(() => {
      try source.push() catch {
        _ => push_failures.val = push_failures.val + 1
      } noraise {
        _ => ()
      }
    })
  })
  assert_true(push_failures.val == 0)
  source_conn.close()
  source.close()

  let replica = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(dir + "/replica.db", remote_url=server.base_url()),
  )
  defer replica.close()
  let replica_conn = replica.connect()
  defer replica_conn.close()
  let bodies : Array[String] = replica_conn.fetch(
    "select body from notes order by id",
  )
  assert_true(bodies.length() == 2)
  assert_true(bodies[0] == "updated")
  assert_true(bodies[1] == "second")
}

///|
async test "sync push failure keeps local changes for retry" {
  match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => ()
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-sync-push-retry")
  defer @fs.rmdir(dir, recursive=true)
  let remote_path = dir + "/remote.db"
  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(remote_path),
  )
  defer @async.protect_from_cancel(async fn() { server.stop() })
  let address = server.base_url()[7:].to_owned()

  let source = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(dir + "/source.db", remote_url=server.base_url()),
  )
  defer source.close()
  let source_conn = source.connect()
  defer source_conn.close()
  ignore(
    source_conn.execute("create table notes(id integer primary key, body text)"),
  )
  ignore(source_conn.execute("insert into notes(body) values ('before')"))
  source.push()

  server.stop()
  ignore(source_conn.execute("insert into notes(body) values ('offline')"))
  let mut network_error = false
  try source.push() catch {
    @mturso.TursoError::SyncError(@mturso.SyncErrorKind::Network, message) => {
      assert_true(message.length() > 0)
      network_error = true
    }
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(network_error)

  let restarted = @server.SyncServer::start(
    @server.SyncServerConfig::new(remote_path, address~),
  )
  defer @async.protect_from_cancel(async fn() { restarted.stop() })
  source.push()

  let replica = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(
      dir + "/replica.db",
      remote_url=restarted.base_url(),
    ),
  )
  defer replica.close()
  let replica_conn = replica.connect()
  defer replica_conn.close()
  let bodies : Array[String] = replica_conn.fetch(
    "select body from notes order by id",
  )
  assert_true(bodies.length() == 2)
  assert_true(bodies[0] == "before")
  assert_true(bodies[1] == "offline")
}
