// Public API lifecycle tests for the sync server library.

///|
async test "sync server rejects non-loopback addresses" {
  let config = @lib.SyncServerConfig::new(":memory:", address="0.0.0.0:8080")
  let mut rejected = false
  try ignore(@lib.SyncServer::start(config)) catch {
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
  let config = @lib.SyncServerConfig::new(
    ":memory:",
    tursodb_path=Some("moon"),
    startup_timeout_ms=100,
  )
  let mut rejected = false
  try ignore(@lib.SyncServer::start(config)) catch {
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
  let config = @lib.SyncServerConfig::new(
    dir + "/server.db",
    tursodb_path=Some(path),
  )
  let server = @lib.SyncServer::start(config)
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
  let config = @lib.SyncServerConfig::new(
    dir,
    tursodb_path=Some(path),
    startup_timeout_ms=1_000,
  )
  let mut rejected = false
  try ignore(@lib.SyncServer::start(config)) catch {
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
  let config = @lib.SyncServerConfig::new(
    dir + "/server.db",
    tursodb_path=Some(path),
    address=occupied.addr.to_string(),
    startup_timeout_ms=1_000,
  )
  let mut rejected = false
  try ignore(@lib.SyncServer::start(config)) catch {
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
