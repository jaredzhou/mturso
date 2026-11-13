///|
priv struct DatabaseExt {}

///|
priv struct SyncStateExt {}

///|
async fn protocol_error(
  ctx : @pony.Context,
  status : Int,
  message : String,
) -> Unit {
  ctx.write_json(status, Map([("error", message)]))
}

///|
fn services_middleware(
  db : @mturso.Database,
  state : @srv.NativeSyncState,
) -> @pony.Middleware {
  next => {
    ctx => {
      ctx.set_ext(DatabaseExt::{ }, db)
      ctx.set_ext(SyncStateExt::{ }, state)
      next(ctx)
    }
  }
}

///|
fn auth_middleware(auth : @srv.SyncServerAuth) -> @pony.Middleware {
  next => {
    ctx => {
      if auth.verify_header(ctx.try_header("authorization")) {
        next(ctx)
        return
      }
      ctx.set_header("WWW-Authenticate", "Bearer realm=\"mturso\"")
      ctx.write_json(401, Map([("error", "Unauthorized")]))
    }
  }
}

///|
async fn handle_pipeline(ctx : @pony.Context) -> Unit {
  let db : @mturso.Database = ctx.get_ext(DatabaseExt::{ }) catch {
    error => {
      protocol_error(ctx, 500, @debug.to_string(error))
      return
    }
  }
  let request : @srv.PipelineRequest = ctx.json() catch {
    error => {
      protocol_error(ctx, 400, "\{error}")
      return
    }
  }
  let response = @srv.process_pipeline_request(db, request)
  if response.status == 200 {
    let body = @json.parse(response.body) catch {
      error => {
        protocol_error(ctx, 500, "invalid pipeline response: \{error}")
        return
      }
    }
    ctx.reply_ok(body)
  } else {
    ctx.set_content_type(response.content_type)
    ctx.write_text(response.status, response.body)
  }
}

///|
async fn handle_cursor(ctx : @pony.Context) -> Unit {
  let db : @mturso.Database = ctx.get_ext(DatabaseExt::{ }) catch {
    error => {
      protocol_error(ctx, 500, @debug.to_string(error))
      return
    }
  }
  let request : @srv.CursorRequest = ctx.json() catch {
    error => {
      protocol_error(ctx, 400, "\{error}")
      return
    }
  }
  let response = @srv.process_cursor_request(db, request)
  ctx.set_content_type(response.content_type)
  ctx.write_text(response.status, response.body)
}

///|
async fn handle_pull_updates(ctx : @pony.Context) -> Unit {
  let state : @srv.NativeSyncState = ctx.get_ext(SyncStateExt::{ }) catch {
    error => {
      protocol_error(ctx, 500, @debug.to_string(error))
      return
    }
  }
  let body = ctx.req_body.read_all() catch {
    error => {
      protocol_error(ctx, 400, "\{error}")
      return
    }
  }
  let response = state.pull(body)
  ctx.set_content_type(response.content_type)
  ctx.write_bytes(response.status, response.body)
}

///|
fn build_router(
  db : @mturso.Database,
  state : @srv.NativeSyncState,
  auth : @srv.SyncServerAuth,
) -> @pony.Router raise @pony.RouterError {
  let router = @pony.Router::Router()
  router.use_mw(services_middleware(db, state))
  let bearer_auth = auth_middleware(auth)
  router.post("/v2/pipeline", mws=[bearer_auth], handle_pipeline)
  router.post("/v3/pipeline", mws=[bearer_auth], handle_pipeline)
  router.post("/v3/cursor", mws=[bearer_auth], handle_cursor)
  router.post("/pull-updates", mws=[bearer_auth], handle_pull_updates)
  router.options("/*", ctx => ctx.no_content())
  router.set_not_found(ctx => protocol_error(ctx, 404, "Not Found"))
  router
}

///|
fn native_auth_from_env() -> @srv.SyncServerAuth {
  match @env.get_env_var("MTURSO_SYNC_BEARER_TOKEN") {
    Some(token) if token != "" => @srv.SyncServerAuth::BearerToken(token)
    _ => @srv.SyncServerAuth::Disabled
  }
}

///|
fn native_proxy_mode_from_env() -> Bool raise @mturso.TursoError {
  match @env.get_env_var("MTURSO_SYNC_EXTERNAL_TLS_PROXY") {
    None | Some("") | Some("0") => false
    Some("1") => true
    Some(_) =>
      raise @mturso.sync_error(
        @mturso.SyncErrorKind::Protocol,
        "MTURSO_SYNC_EXTERNAL_TLS_PROXY must be 0 or 1",
      )
  }
}

///|
async fn run_native_server(database_path : String, address : String) -> Unit {
  let auth = native_auth_from_env()
  let external_tls_proxy = native_proxy_mode_from_env() catch {
    error => {
      println("invalid native server configuration: \{@debug.to_string(error)}")
      @env.exit(1)
    }
  }
  let config = @srv.SyncServerConfig::new(
    database_path,
    address~,
    backend=@srv.SyncServerBackend::Native,
    auth~,
    external_tls_proxy~,
  )
  config.validate() catch {
    @mturso.TursoError::SyncError(_, message) => {
      println("invalid native server configuration: \{message}")
      @env.exit(1)
    }
    error => {
      println("invalid native server configuration: \{@debug.to_string(error)}")
      @env.exit(1)
    }
  }
  let db = @mturso.Database::open(database_path, max_conns=1) catch {
    error => {
      println("failed to open database: \{@debug.to_string(error)}")
      @env.exit(1)
    }
  }
  defer db.close()
  let state = @srv.NativeSyncState::new(db, database_path)
  let router = build_router(db, state, auth) catch {
    error => {
      println("failed to build router: \{error}")
      @env.exit(1)
    }
  }
  println("native sync server listening at http://\{address}")
  if auth.is_enabled() {
    println("native sync server Bearer authentication enabled")
  }
  if external_tls_proxy {
    println("native sync server expects TLS termination by an external proxy")
  }
  @pony.start(address, router)
}
