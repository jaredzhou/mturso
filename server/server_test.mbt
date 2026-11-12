// Public API lifecycle tests for the sync server package.

///|
async test "sync server rejects non-loopback addresses" {
  let config = @server.SyncServerConfig::new(":memory:", address="0.0.0.0:8080")
  let mut rejected = false
  try ignore(@server.SyncServer::start(config)) catch {
    @mturso.TursoError::SyncError(@mturso.SyncErrorKind::Protocol, message) => {
      assert_true(message.contains("loopback"))
      rejected = true
    }
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(rejected)
}

///|
async test "sync server uses only a matching tursodb version" {
  let config = @server.SyncServerConfig::new(
    ":memory:",
    tursodb_path=Some("moon"),
    startup_timeout_ms=100,
  )
  let mut rejected = false
  try ignore(@server.SyncServer::start(config)) catch {
    @mturso.TursoError::SyncError(@mturso.SyncErrorKind::Internal, message) => {
      assert_true(message.contains("v0.8.2"))
      rejected = true
    }
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(rejected)
}

///|
async test "sync server starts, listens, and stops idempotently" {
  let path = match @env.get_env_var("TURSODB") {
    Some(path) if path != "" => path
    _ => return
  }
  let dir = @fs.tmpdir(prefix="mturso-sync-server")
  defer @fs.rmdir(dir, recursive=true)
  let config = @server.SyncServerConfig::new(
    dir + "/server.db",
    tursodb_path=Some(path),
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
  )
  let mut rejected = false
  try ignore(@server.SyncServer::start(config)) catch {
    @mturso.TursoError::SyncError(@mturso.SyncErrorKind::Internal, message) => {
      assert_true(message.contains("exited"))
      rejected = true
    }
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(rejected)
}

///|
async test "sync server reports a bind conflict" {
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
  )
  let mut rejected = false
  try ignore(@server.SyncServer::start(config)) catch {
    @mturso.TursoError::SyncError(@mturso.SyncErrorKind::Internal, message) => {
      assert_true(message.contains("exited"))
      rejected = true
    }
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(rejected)
}

///|
async fn post_pipeline(base_url : String, body : String) -> (Int, String) {
  let client = @http.Client::Client()
  defer client.close()
  let headers : @http.Headers = Map([])
  headers[@http.CaseInsensitiveString("Content-Type")] = "application/json"
  headers[@http.CaseInsensitiveString("Content-Length")] = body
    .length()
    .to_string()
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
async test "native pipeline executes SQL and parameters" {
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
  assert_true(error_pipeline_response.contains("\"code\":\"BATCH_STEP_ERROR\""))

  let (missing_status, missing_body) = @http.get_text(
    server.base_url() + "/missing",
  )
  assert_true(missing_status.code == 404)
  assert_true(missing_body.contains("Not Found"))

  let (bad_status, bad_body) = post_pipeline(server.base_url(), "{")
  assert_true(bad_status == 400)
  assert_true(bad_body.contains("error"))
}
