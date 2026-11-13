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
) -> @pony.Router raise @pony.RouterError {
  let router = @pony.Router::Router()
  router.use_mw(services_middleware(db, state))
  router.post("/v2/pipeline", handle_pipeline)
  router.post("/v3/pipeline", handle_pipeline)
  router.post("/v3/cursor", handle_cursor)
  router.post("/pull-updates", handle_pull_updates)
  router.options("/*", ctx => ctx.no_content())
  router.set_not_found(ctx => protocol_error(ctx, 404, "Not Found"))
  router
}

///|
async fn run_native_server(database_path : String, address : String) -> Unit {
  if !(address.has_prefix("127.0.0.1:") || address.has_prefix("[::1]:")) {
    println("native server only supports loopback addresses")
    @env.exit(1)
  }
  let db = @mturso.Database::open(database_path, max_conns=1) catch {
    error => {
      println("failed to open database: \{@debug.to_string(error)}")
      @env.exit(1)
    }
  }
  defer db.close()
  let state = @srv.NativeSyncState::new(db, database_path)
  let router = build_router(db, state) catch {
    error => {
      println("failed to build router: \{error}")
      @env.exit(1)
    }
  }
  println("native sync server listening at http://\{address}")
  @pony.start(address, router)
}
