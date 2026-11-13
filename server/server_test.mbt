// Public API lifecycle tests for the sync server package.

///|
let server_process_test_lock : @async.Semaphore = @async.Semaphore::Semaphore(1)

///|
test "sync bearer authentication accepts only a valid token" {
  let auth = @server.SyncServerAuth::BearerToken("correct-horse")
  assert_true(auth.verify_header(Some("Bearer correct-horse")))
  assert_true(auth.verify_header(Some("bearer correct-horse")))
  assert_false(auth.verify_header(None))
  assert_false(auth.verify_header(Some("Basic correct-horse")))
  assert_false(auth.verify_header(Some("Bearer wrong-horse")))
  assert_false(auth.verify_header(Some("Bearer correct-horse extra")))
  assert_false(auth.verify_header(Some("Bearer")))
}

///|
test "sync bearer verifier receives the bare token" {
  let seen = Ref("")
  let auth = @server.SyncServerAuth::BearerVerifier(token => {
    seen.val = token
    token == "verified"
  })
  assert_true(auth.verify_header(Some("Bearer verified")))
  assert_true(seen.val == "verified")
  assert_false(auth.verify_header(Some("Bearer rejected")))
}

///|
test "sync server validates proxy and authentication combinations" {
  let config = @server.SyncServerConfig::new(
    ":memory:",
    address="0.0.0.0:8080",
    auth=@server.SyncServerAuth::BearerToken("secret"),
    external_tls_proxy=true,
  )
  config.validate()

  let missing_proxy = @server.SyncServerConfig::new(
    ":memory:",
    address="0.0.0.0:8080",
    auth=@server.SyncServerAuth::BearerToken("secret"),
  )
  let error = @test.expect_error(() => missing_proxy.validate())
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Protocol,
      message,
    ) =>
      assert_eq(
        message,
        "non-loopback sync server binds require external_tls_proxy mode",
      )
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }

  let missing_auth = @server.SyncServerConfig::new(
    ":memory:",
    address="0.0.0.0:8080",
    external_tls_proxy=true,
  )
  let error = @test.expect_error(() => missing_auth.validate())
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Protocol,
      message,
    ) =>
      assert_eq(
        message,
        "external TLS proxy mode requires Bearer authentication",
      )
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }

  let external_auth = @server.SyncServerConfig::new(
    ":memory:",
    backend=@server.SyncServerBackend::External,
    auth=@server.SyncServerAuth::BearerToken("secret"),
  )
  let error = @test.expect_error(() => external_auth.validate())
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Protocol,
      message,
    ) =>
      assert_eq(
        message,
        "external tursodb backend does not support built-in authentication",
      )
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }

  let empty_token = @server.SyncServerConfig::new(
    ":memory:",
    auth=@server.SyncServerAuth::BearerToken(""),
  )
  let error = @test.expect_error(() => empty_token.validate())
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Protocol,
      message,
    ) =>
      assert_eq(message, "Bearer token must not be empty")
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
}

///|
async test "sync server rejects non-loopback addresses" {
  let config = @server.SyncServerConfig::new(
    ":memory:",
    backend=@server.SyncServerBackend::External,
    address="0.0.0.0:8080",
  )
  let error = @test.expect_error_async(() => @server.SyncServer::start(config))
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Protocol,
      message,
    ) =>
      assert_eq(message, "external tursodb backend only supports loopback addresses")
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
}

///|
async test "sync server uses only a matching tursodb version" {
  let config = @server.SyncServerConfig::new(
    ":memory:",
    tursodb_path=Some("moon"),
    startup_timeout_ms=100,
    backend=@server.SyncServerBackend::External,
  )
  let error = @test.expect_error_async(() => @server.SyncServer::start(config))
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Internal,
      message,
    ) => assert_true(message.contains("v0.8.2"))
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
}

///|
async test "sync server starts, listens, and stops idempotently" {
  server_process_test_lock.acquire()
  defer server_process_test_lock.release()
  let path = match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => path
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-sync-server")
  defer @fs.rmdir(dir, recursive=true)
  let config = @server.SyncServerConfig::new(
    dir + "/server.db",
    tursodb_path=Some(path),
    backend=@server.SyncServerBackend::External,
  )
  let server = @server.SyncServer::start(config)
  let base_url = server.base_url()
  assert_true(base_url.has_prefix("http://127.0.0.1:"))
  let address = base_url[7:].to_owned()
  let connection = @socket.Tcp::connect(@socket.Addr::parse(address))
  connection.close()
  server.stop()
  server.stop()
}

///|
async test "sync server reports child early exit" {
  server_process_test_lock.acquire()
  defer server_process_test_lock.release()
  let path = match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => path
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-sync-server-exit")
  defer @fs.rmdir(dir, recursive=true)
  let config = @server.SyncServerConfig::new(
    dir,
    tursodb_path=Some(path),
    startup_timeout_ms=1_000,
    backend=@server.SyncServerBackend::External,
  )
  let error = @test.expect_error_async(() => @server.SyncServer::start(config))
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Internal,
      message,
    ) => assert_true(message.contains("exited"))
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
}

///|
async test "sync server reports a bind conflict" {
  server_process_test_lock.acquire()
  defer server_process_test_lock.release()
  let path = match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => path
    _ => return
  }
  let occupied = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer occupied.close()
  let dir = @fs.tmpdir(prefix="mturso-sync-server-conflict")
  defer @fs.rmdir(dir, recursive=true)
  let config = @server.SyncServerConfig::new(
    dir + "/server.db",
    tursodb_path=Some(path),
    address=occupied.addr.to_string(),
    startup_timeout_ms=1_000,
    backend=@server.SyncServerBackend::External,
  )
  let error = @test.expect_error_async(() => @server.SyncServer::start(config))
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Internal,
      message,
    ) => assert_true(message.contains("exited"))
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
}

///|
async fn post_pipeline_with_auth(
  base_url : String,
  body : String,
  auth_token : String?,
) -> (Int, String) {
  let client = @http.Client::Client()
  defer client.close()
  let headers : @http.Headers = Map([])
  headers[@http.CaseInsensitiveString("Content-Type")] = "application/json"
  headers[@http.CaseInsensitiveString("Content-Length")] = body
    .length()
    .to_string()
  match auth_token {
    Some(token) =>
      headers[@http.CaseInsensitiveString("Authorization")] = "Bearer \{token}"
    None => ()
  }
  let conn = client.request(
    @http.Post,
    "\{base_url}/v2/pipeline",
    extra_headers=headers,
  )
  defer conn.close()
  conn.text.write(body)
  let response = conn.end_request()
  (response.code, conn.text.read_all())
}

///|
async fn post_pipeline(base_url : String, body : String) -> (Int, String) {
  post_pipeline_with_auth(base_url, body, None)
}

///|
async test "native pipeline executes SQL and parameters" {
  server_process_test_lock.acquire()
  defer server_process_test_lock.release()
  let executable = match @env.get_env_var("MTURSO_NATIVE_SERVER") {
    Some(path) if path != "" => path
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-native-pipeline")
  defer @fs.rmdir(dir, recursive=true)
  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      dir + "/pipeline.db",
      backend=@server.SyncServerBackend::Native,
      native_executable=Some(executable),
    ),
  )
  defer @async.protect_from_cancel(async fn() { server.stop() })
  let body =
    #|{"baton":null,"requests":[
    #|{"type":"execute","stmt":{"sql":"create table t(id integer primary key, name text, payload blob, nullable text)"}},
    #|{"type":"execute","stmt":{"sql":"insert into t values (?1, ?2, ?3, ?4)","args":[{"type":"integer","value":"1"},{"type":"text","value":"alice"},{"type":"blob","base64":"3q2+7w"},{"type":"null"}]}},
    #|{"type":"execute","stmt":{"sql":"select id, name, payload, nullable from t"}}
    #|]}
  let (status, response) = post_pipeline(server.base_url(), body)
  assert_true(status == 200)
  let json = @json.parse(response)
  let fields = match json {
    @json.Json::Object(fields) => fields
    _ => fail("pipeline response must be an object")
  }
  let results = match fields.get("results") {
    Some(@json.Json::Array(results)) => results
    _ => fail("pipeline response must contain results")
  }
  assert_true(results.length() == 3)
  assert_true(response.contains("\"type\":\"ok\""))
  assert_true(response.contains("\"value\":\"alice\""))
  assert_true(response.contains("\"base64\":\"3q2+7w\""))

  let batch_body =
    #|{"baton":null,"requests":[{"type":"batch","batch":{"steps":[
    #|{"stmt":{"sql":"update t set name = 'updated' where id = 1"}},
    #|{"condition":{"type":"ok","step":0},"stmt":{"sql":"delete from t where id = 1"}},
    #|{"condition":{"type":"ok","step":1},"stmt":{"sql":"select count(*) from t"}}
    #|]}}]}
  let (batch_status, batch_response) = post_pipeline(
    server.base_url(),
    batch_body,
  )
  assert_true(batch_status == 200)
  assert_true(batch_response.contains("\"type\":\"batch\""))
  assert_true(batch_response.contains("\"value\":\"0\""))

  let error_body =
    #|{"baton":null,"requests":[{"type":"batch","batch":{"steps":[
    #|{"stmt":{"sql":"insert into t values (7, 'first', null, null)"}},
    #|{"condition":{"type":"ok","step":0},"stmt":{"sql":"insert into t values (7, 'duplicate', null, null)"}},
    #|{"condition":{"type":"error","step":1},"stmt":{"sql":"insert into t values (8, 'recovered', null, null)"}}
    #|]}}]}
  let (error_status, error_pipeline_response) = post_pipeline(
    server.base_url(),
    error_body,
  )
  assert_true(error_status == 200)
  assert_true(
    error_pipeline_response.contains("\"code\":\"SQLITE_CONSTRAINT\""),
  )

  let (missing_status, missing_body) = @http.get_text(
    server.base_url() + "/missing",
  )
  assert_true(missing_status.code == 404)
  assert_true(missing_body.contains("Not Found"))

  let (bad_status, bad_body) = post_pipeline(server.base_url(), "{")
  assert_true(bad_status == 400)
  assert_true(bad_body.contains("error"))
}

///|
async test "native sync server enforces bearer authentication end to end" {
  server_process_test_lock.acquire()
  defer server_process_test_lock.release()
  let executable = match @env.get_env_var("MTURSO_NATIVE_SERVER") {
    Some(path) if path != "" => path
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-native-auth")
  defer @fs.rmdir(dir, recursive=true)
  let remote_path = dir + "/remote.db"
  let remote = @mturso.Database::open(remote_path)
  let seed = remote.connect()
  ignore(seed.execute("create table notes(id integer primary key, body text)"))
  ignore(seed.execute("insert into notes(body) values ('base')"))
  seed.close()
  remote.close()

  let token = "integration-secret-value"
  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      remote_path,
      backend=@server.SyncServerBackend::Native,
      native_executable=Some(executable),
      auth=@server.SyncServerAuth::BearerToken(token),
    ),
  )
  defer @async.protect_from_cancel(async fn() { server.stop() })

  let request =
    #|{"baton":null,"requests":[{"type":"execute","stmt":{"sql":"select count(*) from notes"}}]}
  let (missing_status, missing_body) = post_pipeline(server.base_url(), request)
  assert_true(missing_status == 401)
  assert_true(missing_body.contains("Unauthorized"))
  assert_false(missing_body.contains(token))

  let (wrong_status, wrong_body) = post_pipeline_with_auth(
    server.base_url(),
    request,
    Some("wrong-token"),
  )
  assert_true(wrong_status == 401)
  assert_true(wrong_body.contains("Unauthorized"))
  assert_false(wrong_body.contains("wrong-token"))

  let remote_insert =
    #|{"baton":null,"requests":[{"type":"execute","stmt":{"sql":"insert into notes(body) values ('from-server')"}}]}
  let (insert_status, insert_body) = post_pipeline_with_auth(
    server.base_url(),
    remote_insert,
    Some(token),
  )
  assert_true(insert_status == 200)
  assert_false(insert_body.contains("\"type\":\"error\""))

  let first = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(
      dir + "/first.db",
      remote_url=server.base_url(),
      auth_token=Some(token),
      long_poll_timeout_ms=100,
    ),
  )
  defer first.close()
  let first_conn = first.connect()
  let initial : Array[String] = first_conn.fetch(
    "select body from notes order by id",
  )
  assert_true(initial.length() == 2)
  assert_true(initial[0] == "base")
  assert_true(initial[1] == "from-server")
  ignore(first_conn.execute("insert into notes(body) values ('pushed')"))
  first_conn.close()
  first.push()

  let second = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(
      dir + "/second.db",
      remote_url=server.base_url(),
      auth_token=Some(token),
      long_poll_timeout_ms=100,
    ),
  )
  defer second.close()
  let second_conn = second.connect()
  let pushed : Array[String] = second_conn.fetch(
    "select body from notes order by id",
  )
  assert_true(pushed.length() == 3)
  assert_true(pushed[2] == "pushed")
  second_conn.close()

  first.checkpoint()
  let stats = first.stats()
  assert_true(stats.revision.length() > 0)

  let error = @test.expect_error_async(
    () =>
      @mturso.SyncDatabase::open(
        @mturso.SyncConfig::new(
          dir + "/unauthorized.db",
          remote_url=server.base_url(),
          long_poll_timeout_ms=100,
        ),
      ),
  )
  match error {
    @mturso.TursoError::SyncError(
      @mturso.SyncErrorKind::Auth,
      message,
    ) => assert_true(message.contains("authentication"))
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
}

///|
async test "native sync server bootstraps a file-backed database" {
  server_process_test_lock.acquire()
  defer server_process_test_lock.release()
  let executable = match @env.get_env_var("MTURSO_NATIVE_SERVER") {
    Some(path) if path != "" => path
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-native-bootstrap")
  defer @fs.rmdir(dir, recursive=true)
  let remote_path = dir + "/remote.db"
  let remote = @mturso.Database::open(remote_path)
  let seed = remote.connect()
  ignore(seed.execute("create table notes(id integer primary key, body text)"))
  ignore(seed.execute("insert into notes(body) values ('alpha'), ('beta')"))
  seed.close()
  remote.close()

  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      remote_path,
      backend=@server.SyncServerBackend::Native,
      native_executable=Some(executable),
    ),
  )
  defer @async.protect_from_cancel(async fn() { server.stop() })

  let replica = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(
      dir + "/local.db",
      remote_url=server.base_url(),
      long_poll_timeout_ms=100,
    ),
  )
  defer replica.close()
  let conn = replica.connect()
  defer conn.close()
  let bodies : Array[String] = conn.fetch("select body from notes order by id")
  assert_true(bodies.length() == 2)
  assert_true(bodies[0] == "alpha")
  assert_true(bodies[1] == "beta")

  let update_request =
    #|{"baton":null,"requests":[{"type":"execute","stmt":{"sql":"update notes set body = 'beta-updated' where id = 2"}}]}
  let (update_status, update_body) = post_pipeline(
    server.base_url(),
    update_request,
  )
  assert_true(update_status == 200)
  assert_true(!update_body.contains("\"type\":\"error\""))
  assert_true(replica.pull())
  let updated : Array[String] = conn.fetch("select body from notes order by id")
  assert_true(updated.length() == 2)
  assert_true(updated[0] == "alpha")
  assert_true(updated[1] == "beta-updated")

  let snapshot = @fs.read_binary(remote_path)
  let delta = @fs.read_binary(remote_path + ".mturso-sync/revisions/2.delta")
  let changed_pages = delta[8].to_uint() |
    (delta[9].to_uint() << 8) |
    (delta[10].to_uint() << 16) |
    (delta[11].to_uint() << 24)
  assert_true(changed_pages.reinterpret_as_int() < snapshot.length() / 4096)

  let insert_request =
    #|{"baton":null,"requests":[{"type":"execute","stmt":{"sql":"insert into notes(body) values ('gamma')"}}]}
  let (insert_status, insert_body) = post_pipeline(
    server.base_url(),
    insert_request,
  )
  assert_true(insert_status == 200)
  assert_true(!insert_body.contains("\"type\":\"error\""))
  assert_true(replica.pull())
  let count : Array[Int] = conn.fetch("select count(*) from notes")
  assert_true(count.length() == 1)
  assert_true(count[0] == 3)

  let started = @async.now()
  assert_true(!replica.pull())
  assert_true(@async.now() - started >= 80L)
  assert_true(@fs.read_text(remote_path + ".mturso-sync/state").trim() == "3")
}

///|
async test "native pull updates rejects a truncated protobuf request" {
  let dir = @fs.tmpdir(prefix="mturso-native-pull-truncated")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/remote.db"
  let db = @mturso.Database::open(path)
  defer db.close()
  let response = @server.NativeSyncState::new(db, path).pull(b"\x12\x05x")
  assert_true(response.status == 400)
  assert_true(
    @utf8.decode_lossy(response.body).contains("invalid pull-updates request"),
  )
}

///|
async test "native sync server keeps bootstrap state across restart" {
  server_process_test_lock.acquire()
  defer server_process_test_lock.release()
  let executable = match @env.get_env_var("MTURSO_NATIVE_SERVER") {
    Some(path) if path != "" => path
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-native-restart")
  defer @fs.rmdir(dir, recursive=true)
  let remote_path = dir + "/remote.db"
  let remote = @mturso.Database::open(remote_path)
  let seed = remote.connect()
  ignore(seed.execute("create table notes(id integer primary key, body text)"))
  ignore(seed.execute("insert into notes(body) values ('persisted')"))
  seed.close()
  remote.close()

  let first = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      remote_path,
      backend=@server.SyncServerBackend::Native,
      native_executable=Some(executable),
    ),
  )
  let address = first.base_url()[7:].to_owned()
  let first_replica = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(
      dir + "/first.db",
      remote_url=first.base_url(),
      long_poll_timeout_ms=100,
    ),
  )
  let first_conn = first_replica.connect()
  let first_rows : Array[String] = first_conn.fetch("select body from notes")
  assert_true(first_rows.length() == 1)
  assert_true(first_rows[0] == "persisted")
  first_conn.close()
  first_replica.close()
  first.stop()

  let second = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      remote_path,
      backend=@server.SyncServerBackend::Native,
      native_executable=Some(executable),
      address~,
    ),
  )
  defer @async.protect_from_cancel(async fn() { second.stop() })
  let second_replica = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(
      dir + "/second.db",
      remote_url=second.base_url(),
      long_poll_timeout_ms=100,
    ),
  )
  defer second_replica.close()
  let second_conn = second_replica.connect()
  defer second_conn.close()
  let second_rows : Array[String] = second_conn.fetch("select body from notes")
  assert_true(second_rows.length() == 1)
  assert_true(second_rows[0] == "persisted")
  assert_true(second_replica.stats().revision.length() > 0)

  let restart_update_request =
    #|{"baton":null,"requests":[{"type":"execute","stmt":{"sql":"insert into notes(body) values ('after-restart')"}}]}
  let (restart_update_status, restart_update_body) = post_pipeline(
    second.base_url(),
    restart_update_request,
  )
  assert_true(restart_update_status == 200)
  assert_true(!restart_update_body.contains("\"type\":\"error\""))
  assert_true(second_replica.pull())
  let after_restart : Array[String] = second_conn.fetch(
    "select body from notes order by id",
  )
  assert_true(after_restart.length() == 2)
  assert_true(after_restart[1] == "after-restart")
}

///|
async test "native sync server applies last push wins across replicas" {
  server_process_test_lock.acquire()
  defer server_process_test_lock.release()
  let executable = match @env.get_env_var("MTURSO_NATIVE_SERVER") {
    Some(path) if path != "" => path
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-native-push")
  defer @fs.rmdir(dir, recursive=true)
  let remote_path = dir + "/remote.db"
  let remote = @mturso.Database::open(remote_path)
  let seed = remote.connect()
  ignore(seed.execute("create table notes(id integer primary key, body text)"))
  ignore(seed.execute("insert into notes(id, body) values (1, 'base')"))
  seed.close()
  remote.close()

  let server = @server.SyncServer::start(
    @server.SyncServerConfig::new(
      remote_path,
      backend=@server.SyncServerBackend::Native,
      native_executable=Some(executable),
    ),
  )
  defer @async.protect_from_cancel(async fn() { server.stop() })

  let first = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(
      dir + "/first.db",
      remote_url=server.base_url(),
      long_poll_timeout_ms=100,
    ),
  )
  defer first.close()
  let first_conn = first.connect()
  defer first_conn.close()
  ignore(
    first_conn.execute("insert into notes(id, body) values (2, 'first-push')"),
  )
  first.push()

  let second = @mturso.SyncDatabase::open(
    @mturso.SyncConfig::new(
      dir + "/second.db",
      remote_url=server.base_url(),
      long_poll_timeout_ms=100,
    ),
  )
  defer second.close()
  let second_conn = second.connect()
  defer second_conn.close()
  ignore(
    second_conn.execute("update notes set body = 'second-push' where id = 1"),
  )
  second.push()

  assert_true(first.pull())
  let rows : Array[(Int, String)] = first_conn.fetch(
    "select id, body from notes order by id",
  )
  assert_true(rows.length() == 2)
  assert_true(rows[0].1 == "second-push")
  assert_true(rows[1].1 == "first-push")

  first.push()
  first.push()
  let count : Array[Int] = first_conn.fetch("select count(*) from notes")
  assert_true(count.length() == 1)
  assert_true(count[0] == 2)
}
