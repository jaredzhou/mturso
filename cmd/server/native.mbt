///|
async fn handle_pipeline(db : @mturso.Database, ctx : @pony.Context) -> Unit {
  let body = try ctx.req_body.read_all() catch {
    error => {
      ctx.write_json(400, Map([("error", "\{error}")]))
      return
    }
  } noraise {
    value => value
  }
  let response = @srv.process_pipeline_request(db, body)
  ctx.set_content_type(response.content_type)
  ctx.write_text(response.status, response.body)
}

///|
async fn handle_cursor(db : @mturso.Database, ctx : @pony.Context) -> Unit {
  let body = try ctx.req_body.read_all() catch {
    error => {
      ctx.write_json(400, Map([("error", "\{error}")]))
      return
    }
  } noraise {
    value => value
  }
  let response = @srv.process_cursor_request(db, body)
  ctx.set_content_type(response.content_type)
  ctx.write_text(response.status, response.body)
}

///|
async fn handle_pull_updates(
  db : @mturso.Database,
  database_path : String,
  ctx : @pony.Context,
) -> Unit {
  let body = try ctx.req_body.read_all() catch {
    error => {
      ctx.write_json(400, Map([("error", "\{error}")]))
      return
    }
  } noraise {
    value => value
  }
  let response = @srv.process_pull_updates_request(db, database_path, body)
  ctx.set_content_type(response.content_type)
  ctx.write_bytes(response.status, response.body)
}

///|
fn build_router(
  db : @mturso.Database,
  database_path : String,
) -> @pony.Router raise @pony.RouterError {
  let router = @pony.Router::Router()
  router.post("/v2/pipeline", ctx => handle_pipeline(db, ctx))
  router.post("/v3/pipeline", ctx => handle_pipeline(db, ctx))
  router.post("/v3/cursor", ctx => handle_cursor(db, ctx))
  router.post("/pull-updates", ctx => {
    handle_pull_updates(db, database_path, ctx)
  })
  router.options("/*", ctx => ctx.no_content())
  router.set_not_found(ctx => ctx.write_json(404, Map([("error", "Not Found")])))
  router
}

///|
async fn run_native_server(database_path : String, address : String) -> Unit {
  if !(address.has_prefix("127.0.0.1:") || address.has_prefix("[::1]:")) {
    println("native server only supports loopback addresses")
    @env.exit(1)
  }
  let db = try @mturso.Database::open(database_path) catch {
    error => {
      println("failed to open database: \{@debug.to_string(error)}")
      @env.exit(1)
    }
  } noraise {
    value => value
  }
  defer db.close()
  let router = try build_router(db, database_path) catch {
    error => {
      println("failed to build router: \{error}")
      @env.exit(1)
    }
  } noraise {
    value => value
  }
  println("native sync server listening at http://\{address}")
  @pony.start(address, router)
}
