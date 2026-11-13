///|
let sync_test_lock : @async.Semaphore = @async.Semaphore::Semaphore(1)

///|
async test "sync database opens offline when bootstrap is disabled" {
  sync_test_lock.acquire()
  defer sync_test_lock.release()
  let dir = @fs.tmpdir(prefix="mturso-sync-offline")
  defer @fs.rmdir(dir, recursive=true)
  let config = @mturso.SyncConfig::new(
    dir + "/local.db",
    remote_url="http://127.0.0.1:1",
    bootstrap_if_empty=false,
  )
  let db = @mturso.SyncDatabase::open(config)
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
  sync_test_lock.acquire()
  defer sync_test_lock.release()
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
    @server.SyncServerConfig::new(
      remote_path,
      backend=@server.SyncServerBackend::External,
    ),
  )
  defer @async.protect_from_cancel(async fn() { server.stop() })
  let config = @mturso.SyncConfig::new(
    dir + "/local.db",
    remote_url=server.base_url(),
  )
  let db = @mturso.SyncDatabase::open(config)
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
  sync_test_lock.acquire()
  defer sync_test_lock.release()
  let dir = @fs.tmpdir(prefix="mturso-sync-invalid-url")
  defer @fs.rmdir(dir, recursive=true)
  let config = @mturso.SyncConfig::new(
    dir + "/local.db",
    remote_url="not-a-url",
  )
  let error = @test.expect_error_async(
    () => @mturso.SyncDatabase::open(config),
  )
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Protocol,
      message,
    ) =>
      assert_eq(
        message,
        "remote_url must start with http://, https://, libsql://, or turso://",
      )
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
}

///|
async test "sync database reports network failure during bootstrap" {
  sync_test_lock.acquire()
  defer sync_test_lock.release()
  let dir = @fs.tmpdir(prefix="mturso-sync-network-error")
  defer @fs.rmdir(dir, recursive=true)
  let config = @mturso.SyncConfig::new(
    dir + "/local.db",
    remote_url="http://127.0.0.1:1",
  )
  let error = @test.expect_error_async(
    () => @mturso.SyncDatabase::open(config),
  )
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Network,
      message,
    ) => assert_true(message.length() > 0)
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
}

///|
async test "sync database pushes committed local changes" {
  sync_test_lock.acquire()
  defer sync_test_lock.release()
  match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => ()
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-sync-push")
  defer @fs.rmdir(dir, recursive=true)
  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      dir + "/remote.db",
      backend=@server.SyncServerBackend::External,
    ),
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
  @async.with_task_group(group => {
    group.spawn_bg(() => source.push())
    group.spawn_bg(() => source.push())
  })
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
  sync_test_lock.acquire()
  defer sync_test_lock.release()
  match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => ()
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-sync-push-retry")
  defer @fs.rmdir(dir, recursive=true)
  let remote_path = dir + "/remote.db"
  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      remote_path,
      backend=@server.SyncServerBackend::External,
    ),
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
  let error = @test.expect_error_async(() => source.push())
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Network,
      message,
    ) => assert_true(message.length() > 0)
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }

  let restarted = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      remote_path,
      address~,
      backend=@server.SyncServerBackend::External,
    ),
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

///|
async test "sync pull applies remote changes and replays local changes" {
  sync_test_lock.acquire()
  defer sync_test_lock.release()
  match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => ()
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-sync-pull")
  defer @fs.rmdir(dir, recursive=true)
  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      dir + "/remote.db",
      backend=@server.SyncServerBackend::External,
    ),
  )
  defer @async.protect_from_cancel(async fn() { server.stop() })
  let address = server.base_url()[7:].to_owned()

  let writer = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(
      dir + "/writer.db",
      remote_url=server.base_url(),
      long_poll_timeout_ms=50,
    ),
  )
  defer writer.close()
  let writer_conn = writer.connect()
  defer writer_conn.close()
  ignore(
    writer_conn.execute("create table notes(id integer primary key, body text)"),
  )
  ignore(writer_conn.execute("insert into notes(id, body) values (1, 'seed')"))
  writer.push()

  let source = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(
      dir + "/source.db",
      remote_url=server.base_url(),
      long_poll_timeout_ms=50,
    ),
  )
  defer source.close()
  let source_conn = source.connect()
  defer source_conn.close()
  ignore(
    source_conn.execute(
      "insert into notes(id, body) values (10, 'local-unpushed')",
    ),
  )

  ignore(
    writer_conn.execute(
      "insert into notes(id, body) values (20, 'remote-change')",
    ),
  )
  writer.push()
  assert_true(source.pull())
  let bodies : Array[String] = source_conn.fetch(
    "select body from notes order by id",
  )
  assert_true(bodies.length() == 3)
  assert_true(bodies[0] == "seed")
  assert_true(bodies[1] == "local-unpushed")
  assert_true(bodies[2] == "remote-change")
  assert_true(!source.pull())

  ignore(
    writer_conn.execute(
      "insert into notes(id, body) values (30, 'after-restart')",
    ),
  )
  writer.push()
  server.stop()
  let error = @test.expect_error_async(() => source.pull())
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Network,
      message,
    ) => assert_true(message.length() > 0)
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
  let before_restart : Array[String] = source_conn.fetch(
    "select body from notes order by id",
  )
  assert_true(before_restart.length() == 3)

  let restarted = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      dir + "/remote.db",
      address~,
      backend=@server.SyncServerBackend::External,
    ),
  )
  defer @async.protect_from_cancel(async fn() { restarted.stop() })
  assert_true(source.pull())
  let after_restart : Array[String] = source_conn.fetch(
    "select body from notes order by id",
  )
  assert_true(after_restart.length() == 4)
  assert_true(after_restart[3] == "after-restart")

  @async.with_task_group(group => {
    group.spawn_bg(() => ignore(source.pull()))
    group.spawn_bg(() => source.push())
  })
}

///|
async test "sync database reports stats and checkpoints the WAL" {
  sync_test_lock.acquire()
  defer sync_test_lock.release()
  match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => ()
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-sync-stats")
  defer @fs.rmdir(dir, recursive=true)
  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      dir + "/remote.db",
      backend=@server.SyncServerBackend::External,
    ),
  )
  defer @async.protect_from_cancel(async fn() { server.stop() })

  let source = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(dir + "/source.db", remote_url=server.base_url()),
  )
  defer source.close()
  let conn = source.connect()
  defer conn.close()
  ignore(conn.execute("create table notes(id integer primary key, body text)"))
  ignore(conn.execute("insert into notes(id, body) values (1, 'before')"))
  source.push()
  let before = source.stats()
  assert_true(before.revision.length() > 0)
  assert_true(before.main_wal_size >= 0L)
  assert_true(before.network_sent_bytes > 0L)
  assert_true(before.network_received_bytes > 0L)
  assert_true(before.last_pull_unix_time > 0L)
  assert_true(before.last_push_unix_time > 0L)
  source.checkpoint()
  let after = source.stats()
  assert_true(after.main_wal_size < before.main_wal_size)

  ignore(conn.execute("insert into notes(id, body) values (2, 'after')"))
  source.push()
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
  assert_true(bodies[1] == "after")
}

///|
async test "sync database close rejects new work while draining operations" {
  sync_test_lock.acquire()
  defer sync_test_lock.release()
  match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => ()
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-sync-close")
  defer @fs.rmdir(dir, recursive=true)
  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      dir + "/remote.db",
      backend=@server.SyncServerBackend::External,
    ),
  )
  defer @async.protect_from_cancel(async fn() { server.stop() })
  let source = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(
      dir + "/source.db",
      remote_url=server.base_url(),
      long_poll_timeout_ms=300,
    ),
  )
  let conn = source.connect()
  let pulled : Ref[Bool?] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => pulled.val = Some(source.pull()))
    @async.sleep(50)
    source.close()
    assert_true(source.is_closed())
    let error = @test.expect_error_async(() => source.push())
    match error {
      @mturso.TursoError::ConnectionError(message) =>
        assert_eq(message, "sync database is closed")
      error => fail("unexpected error: \{@debug.to_string(error)}")
    }
    let error = @test.expect_error_async(() => source.stats())
    match error {
      @mturso.TursoError::ConnectionError(message) =>
        assert_eq(message, "sync database is closed")
      error => fail("unexpected error: \{@debug.to_string(error)}")
    }
    let error = @test.expect_error_async(() => source.checkpoint())
    match error {
      @mturso.TursoError::ConnectionError(message) =>
        assert_eq(message, "sync database is closed")
      error => fail("unexpected error: \{@debug.to_string(error)}")
    }
    let error = @test.expect_error_async(
      () => conn.execute("select 1"),
    )
    match error {
      @mturso.TursoError::ConnectionError(message) =>
        assert_eq(message, "connection is not open")
      error => fail("unexpected error: \{@debug.to_string(error)}")
    }
  })
  assert_true(pulled.val == Some(false))
  conn.close()
}
