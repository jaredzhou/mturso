///|
async fn main {
  let args = @env.args()
  if args.length() >= 2 && args[1] == "--serve-native" {
    if args.length() < 4 {
      println(
        "usage: mturso-server --serve-native <database-path> <address>",
      )
      @env.exit(1)
    }
    run_native_server(args[2], args[3])
    return
  }
  let use_tursodb = args.length() >= 2 && args[1] == "--tursodb"
  let first = if use_tursodb { 2 } else { 1 }
  if args.length() <= first {
    println(
      "usage: mturso-server [--tursodb] <database-path> [address]",
    )
    @env.exit(1)
  }
  let database_path = args[first]
  let mut address = "127.0.0.1:8080"
  let mut address_set = false
  let mut index = first + 1
  while index < args.length() {
    if !address_set {
      address = args[index]
      address_set = true
      index = index + 1
    } else {
      println("unexpected argument: \{args[index]}")
      @env.exit(1)
    }
  }
  if !use_tursodb {
    run_native_server(database_path, address)
    return
  }
  let config = @srv.SyncServerConfig::new(
    database_path,
    address~,
    backend=@srv.SyncServerBackend::External,
  )
  let server = @srv.SyncServer::start(config) catch {
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
