///|
async fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: mturso-server <database-path> [loopback-address]")
    @env.exit(1)
  }
  let database_path = args[1]
  let address = if args.length() >= 3 { args[2] } else { "127.0.0.1:8080" }
  let config = @lib.SyncServerConfig::new(database_path, address~)
  let server = @lib.SyncServer::start(config) catch {
    @mturso.TursoError::SyncError(kind, message) => {
      println(
        "failed to start sync server (\{@debug.to_string(kind)}): \{message}",
      )
      @env.exit(1)
    }
    error => {
      println("failed to start sync server: \{@debug.to_string(error)}")
      @env.exit(1)
    }
  }
  defer (try @async.protect_from_cancel(async fn() { server.stop() }) catch {
    _ => ()
  } noraise {
    _ => ()
  })
  println("sync server listening at \{server.base_url()}")
  let code = server.wait()
  if code != 0 {
    println("sync server exited with code \{code}")
    @env.exit(code)
  }
}
