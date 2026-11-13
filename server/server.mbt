// Local Turso sync server lifecycle for the external-server phase.

///|
/// Selects the server implementation managed by the shared facade.
pub(all) enum SyncServerBackend {
  External
  Native
}

///|
pub struct SyncServerConfig {
  priv database_path : String
  priv tursodb_path : String?
  priv native_executable : String?
  priv address : String
  priv startup_timeout_ms : Int
  priv backend : SyncServerBackend
  priv auth : SyncServerAuth
  priv external_tls_proxy : Bool
}

///|
pub fn SyncServerConfig::new(
  database_path : String,
  tursodb_path~ : String? = None,
  native_executable~ : String? = None,
  address~ : String = "127.0.0.1:0",
  startup_timeout_ms~ : Int = 10_000,
  backend~ : SyncServerBackend = Native,
  auth~ : SyncServerAuth = Disabled,
  external_tls_proxy~ : Bool = false,
) -> SyncServerConfig {
  {
    database_path,
    tursodb_path,
    native_executable,
    address,
    startup_timeout_ms,
    backend,
    auth,
    external_tls_proxy,
  }
}

///|
pub struct SyncServer {
  priv process : @process.OrphanProcess
  priv base_url : String
  priv closed : Ref[Bool]
}

///|
fn sync_server_error(
  kind : @mturso.SyncErrorKind,
  message : String,
) -> @mturso.TursoError {
  @mturso.sync_error(kind, message)
}

///|
fn resolve_tursodb_path(configured : String?) -> String {
  match configured {
    Some(path) if path != "" => path
    _ =>
      match @env.get_env_var("TURSODB") {
        Some(path) if path != "" => path
        _ => "tursodb"
      }
  }
}

///|
fn resolve_native_executable(
  configured : String?,
) -> String raise @mturso.TursoError {
  match configured {
    Some(path) if path != "" => path
    _ =>
      match @env.get_env_var("MTURSO_NATIVE_SERVER") {
        Some(path) if path != "" => path
        _ =>
          raise sync_server_error(
            @mturso.SyncErrorKind::Internal,
            "native server executable is not configured; set native_executable or MTURSO_NATIVE_SERVER",
          )
      }
  }
}

///|
async fn check_tursodb_version(path : String) -> Unit raise @mturso.TursoError {
  let result = try
    @process.run(
      path,
      ["--version"],
      stdout=Collect,
      stderr=Collect,
      no_console_window=true,
    )
  catch {
    error =>
      raise sync_server_error(
        @mturso.SyncErrorKind::Internal,
        "failed to execute \{path}: \{error}",
      )
  } noraise {
    value => value
  }
  let output = result.stdout_text() catch { _ => "" }
  let diagnostics = result.stderr_text() catch { _ => "" }
  if result.exit_code != 0 || !output.contains("0.8.2") {
    raise sync_server_error(
      @mturso.SyncErrorKind::Internal,
      "tursodb must be v0.8.2: \{path}; exit=\{result.exit_code}; output=\{output}; stderr=\{diagnostics}",
    )
  }
}

///|
fn is_loopback_address(address : String) -> Bool {
  address.has_prefix("127.") || address.has_prefix("[::1]:")
}

///|
/// Validate security-sensitive bind and authentication settings before
/// starting any backend or opening the database.
pub fn SyncServerConfig::validate(
  self : SyncServerConfig,
) -> Unit raise @mturso.TursoError {
  if self.startup_timeout_ms <= 0 {
    raise sync_server_error(
      @mturso.SyncErrorKind::Protocol,
      "startup_timeout_ms must be positive",
    )
  }
  match self.auth {
    BearerToken(token) if token == "" =>
      raise sync_server_error(
        @mturso.SyncErrorKind::Protocol,
        "Bearer token must not be empty",
      )
    _ => ()
  }
  let loopback = is_loopback_address(self.address)
  match self.backend {
    External => {
      if !loopback {
        raise sync_server_error(
          @mturso.SyncErrorKind::Protocol,
          "external tursodb backend only supports loopback addresses",
        )
      }
      if self.auth.is_enabled() {
        raise sync_server_error(
          @mturso.SyncErrorKind::Protocol,
          "external tursodb backend does not support built-in authentication",
        )
      }
    }
    Native => {
      if self.external_tls_proxy && !self.auth.is_enabled() {
        raise sync_server_error(
          @mturso.SyncErrorKind::Protocol,
          "external TLS proxy mode requires Bearer authentication",
        )
      }
      if !loopback && !self.external_tls_proxy {
        raise sync_server_error(
          @mturso.SyncErrorKind::Protocol,
          "non-loopback sync server binds require external_tls_proxy mode",
        )
      }
      if !loopback && !self.auth.is_enabled() {
        raise sync_server_error(
          @mturso.SyncErrorKind::Protocol,
          "non-loopback sync server binds require Bearer authentication",
        )
      }
    }
  }
}

///|
async fn allocate_port(address : String) -> String raise @mturso.TursoError {
  let parsed = @socket.Addr::parse(address) catch {
    error =>
      raise sync_server_error(
        @mturso.SyncErrorKind::Protocol,
        "invalid SyncServer address \{address}: \{error}",
      )
  }
  if parsed.port() != 0 {
    return parsed.to_string()
  }
  let probe = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")) catch {
    error =>
      raise sync_server_error(
        @mturso.SyncErrorKind::Network,
        "failed to allocate a loopback port: \{error}",
      )
  }
  let port = probe.addr.port()
  probe.close()
  "127.0.0.1:\{port}"
}

///|
priv enum SyncServerStartup {
  Listening
  Timeout
  Exited(Int)
}

///|
async fn wait_until_listening(
  address : String,
  timeout_ms : Int,
  auth : SyncServerAuth,
) -> SyncServerStartup {
  let parsed = @socket.Addr::parse(address) catch {
    _ => return SyncServerStartup::Timeout
  }
  let headers : @http.Headers = Map([])
  headers[@http.CaseInsensitiveString("content-type")] = "application/json"
  match auth {
    BearerToken(token) =>
      headers[@http.CaseInsensitiveString("authorization")] = "Bearer \{token}"
    _ => ()
  }
  let started = @async.now()
  @async.sleep(50)
  for ;; {
    let healthy = try
      @async.with_timeout(250, () => {
        ignore(@http.post_text("http://\{parsed}", "{}", headers~))
      })
    catch {
      _ => false
    } noraise {
      _ => true
    }
    if healthy {
      return SyncServerStartup::Listening
    }
    if @async.now() - started >= timeout_ms.to_int64() {
      return SyncServerStartup::Timeout
    }
    @async.sleep(20)
  }
}

///|
async fn terminate_process(process : @process.OrphanProcess) -> Unit {
  let cancel = @process.hard_cancel()
  try cancel(process.pid) catch {
    _ => ()
  } noraise {
    _ => ()
  }
  try ignore(process.wait()) catch {
    _ => ()
  } noraise {
    _ => ()
  }
  process.close()
}

///|
pub async fn SyncServer::start(
  config : SyncServerConfig,
) -> SyncServer raise @mturso.TursoError {
  config.validate()
  let executable = match config.backend {
    External => {
      let executable = resolve_tursodb_path(config.tursodb_path)
      check_tursodb_version(executable)
      executable
    }
    Native => {
      match config.auth {
        BearerVerifier(_) =>
          raise sync_server_error(
            @mturso.SyncErrorKind::Protocol,
            "BearerVerifier cannot be passed to a spawned native server; use BearerToken or run the native server in-process",
          )
        _ => ()
      }
      resolve_native_executable(config.native_executable)
    }
  }
  let address = allocate_port(config.address)
  let process_args = match config.backend {
    External => [config.database_path, "--sync-server", address]
    Native => ["--serve-native", config.database_path, address]
  }
  let diagnostic_path = config.database_path + ".native-server.log"
  let stderr = match config.backend {
    External => @process.Discard
    Native => @process.ToFile(diagnostic_path)
  }
  let child_env = Map([
    ("MTURSO_SYNC_BEARER_TOKEN", ""),
    ("MTURSO_SYNC_EXTERNAL_TLS_PROXY", "0"),
  ])
  match config.auth {
    BearerToken(token) => child_env["MTURSO_SYNC_BEARER_TOKEN"] = token
    _ => ()
  }
  if config.external_tls_proxy {
    child_env["MTURSO_SYNC_EXTERNAL_TLS_PROXY"] = "1"
  }
  let process = try
    @process.spawn_orphan(
      executable,
      process_args,
      extra_env=child_env,
      stdout=Discard,
      stderr~,
      no_console_window=true,
    )
  catch {
    error =>
      raise sync_server_error(
        @mturso.SyncErrorKind::Internal,
        "failed to start sync server process: \{error}",
      )
  } noraise {
    value => value
  }
  let startup = try
    @async.any([
      () => wait_until_listening(address, config.startup_timeout_ms, config.auth),
      () => SyncServerStartup::Exited(process.wait()),
    ])
  catch {
    error => {
      try @async.protect_from_cancel(() => terminate_process(process)) catch {
        _ => ()
      } noraise {
        _ => ()
      }
      raise sync_server_error(
        @mturso.SyncErrorKind::Internal,
        "failed while waiting for tursodb startup: \{error}",
      )
    }
  } noraise {
    value => value
  }
  match startup {
    Listening => ()
    Exited(code) => {
      let diagnostics = try @fs.read_text(diagnostic_path) catch {
        _ => ""
      } noraise {
        value => value
      }
      process.close()
      raise sync_server_error(
        @mturso.SyncErrorKind::Internal,
        "server exited with code \{code} before listening on \{address}: \{diagnostics}",
      )
    }
    Timeout => {
      try @async.protect_from_cancel(() => terminate_process(process)) catch {
        _ => ()
      } noraise {
        _ => ()
      }
      raise sync_server_error(
        @mturso.SyncErrorKind::Network,
        "Turso sync server did not listen on \{address} within \{config.startup_timeout_ms}ms",
      )
    }
  }
  { process, base_url: "http://\{address}", closed: Ref(false), }
}

///|
pub fn SyncServer::base_url(self : SyncServer) -> String {
  self.base_url
}

///|
pub async fn SyncServer::wait(self : SyncServer) -> Int {
  if self.closed.val {
    return 0
  }
  let code = try self.process.wait() catch {
    _ => -1
  } noraise {
    value => value
  }
  self.closed.val = true
  self.process.close()
  code
}

///|
pub async fn SyncServer::stop(self : SyncServer) -> Unit {
  if self.closed.val {
    return
  }
  self.closed.val = true
  @async.protect_from_cancel(async fn() { terminate_process(self.process) })
}
