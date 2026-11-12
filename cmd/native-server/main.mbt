///|
fn object(entries : Array[(String, @json.Json)]) -> @json.Json {
  let fields = Map([])
  for entry in entries {
    fields[entry.0] = entry.1
  }
  @json.Json::object(fields)
}

///|
fn error_object(code : String, message : String) -> @json.Json {
  object([
    ("message", @json.Json::string(message)),
    ("code", @json.Json::string(code)),
  ])
}

///|
fn error_response(_status : Int, message : String) -> @json.Json {
  object([("error", @json.Json::string(message))])
}

///|
fn ok_result(kind : String, result : @json.Json) -> @json.Json {
  object([
    ("type", @json.Json::string("ok")),
    (
      "response",
      object([("type", @json.Json::string(kind)), ("result", result)]),
    ),
  ])
}

///|
fn error_result(error : @json.Json) -> @json.Json {
  object([("type", @json.Json::string("error")), ("error", error)])
}

///|
fn as_object(value : @json.Json) -> Map[String, @json.Json] raise {
  match value {
    @json.Json::Object(fields) => fields
    _ => raise Failure::Failure("expected JSON object")
  }
}

///|
fn as_array(value : @json.Json) -> Array[@json.Json] raise {
  match value {
    @json.Json::Array(items) => items
    _ => raise Failure::Failure("expected JSON array")
  }
}

///|
fn as_string(value : @json.Json) -> String raise {
  match value {
    @json.Json::String(value) => value
    _ => raise Failure::Failure("expected JSON string")
  }
}

///|
fn field(fields : Map[String, @json.Json], name : String) -> @json.Json? {
  fields.get(name)
}

///|
fn decode_value(value : @json.Json) -> @mturso.Value raise {
  let fields = as_object(value)
  let kind = match field(fields, "type") {
    Some(value) => as_string(value)
    None => raise Failure::Failure("value.type is required")
  }
  match kind {
    "null" => @mturso.Value::Null
    "integer" => {
      let raw = match field(fields, "value") {
        Some(value) => as_string(value)
        None => raise Failure::Failure("integer value is required")
      }
      @mturso.Value::Integer(@string.parse_int64(raw))
    }
    "float" =>
      match field(fields, "value") {
        Some(@json.Json::Number(value, ..)) => @mturso.Value::Real(value)
        Some(@json.Json::Null) | None => @mturso.Value::Real(0.0 / 0.0)
        _ => raise Failure::Failure("invalid float value")
      }
    "text" => {
      let raw = match field(fields, "value") {
        Some(value) => as_string(value)
        None => raise Failure::Failure("text value is required")
      }
      @mturso.Value::Text(raw)
    }
    "blob" => {
      let raw = match field(fields, "base64") {
        Some(value) => as_string(value)
        None => raise Failure::Failure("blob base64 is required")
      }
      @mturso.Value::Blob(@base64.decode(raw))
    }
    _ => raise Failure::Failure("unknown value type: \{kind}")
  }
}

///|
fn encode_value(value : @mturso.Value) -> @json.Json {
  match value {
    @mturso.Value::Null => object([("type", @json.Json::string("null"))])
    @mturso.Value::Integer(value) =>
      object([
        ("type", @json.Json::string("integer")),
        ("value", @json.Json::string(value.to_string())),
      ])
    @mturso.Value::Real(value) =>
      object([
        ("type", @json.Json::string("float")),
        ("value", @json.Json::number(value)),
      ])
    @mturso.Value::Text(value) =>
      object([
        ("type", @json.Json::string("text")),
        ("value", @json.Json::string(value)),
      ])
    @mturso.Value::Blob(value) =>
      object([
        ("type", @json.Json::string("blob")),
        ("base64", @json.Json::string(@base64.encode(value, padding=false))),
      ])
  }
}

///|
fn decode_args(stmt : Map[String, @json.Json]) -> Array[@mturso.Value] raise {
  let args = match field(stmt, "args") {
    Some(value) => as_array(value)
    None => []
  }
  let values = []
  for arg in args {
    values.push(decode_value(arg))
  }
  if field(stmt, "named_args") is Some(named) && !as_array(named).is_empty() {
    raise Failure::Failure("named_args are not supported")
  }
  values
}

///|
async fn execute_statement(
  conn : @mturso.Connection,
  stmt : Map[String, @json.Json],
) -> @json.Json {
  let sql = match field(stmt, "sql") {
    Some(value) => as_string(value)
    None => raise Failure::Failure("No SQL provided")
  }
  let args = decode_args(stmt)
  let want_rows = match field(stmt, "want_rows") {
    Some(@json.Json::True) | None => true
    Some(@json.Json::False) => false
    _ => raise Failure::Failure("want_rows must be a boolean")
  }
  let rows = conn.query_values(sql, args)
  defer rows.close()
  let columns = rows.columns()
  let encoded_columns = []
  for column in columns {
    encoded_columns.push(
      object([
        ("name", @json.Json::string(column.name)),
        ("decltype", @json.Json::string(column.decltype)),
      ]),
    )
  }
  let encoded_rows = []
  while rows.has_next() {
    let row = rows.get_row()
    let values = []
    for i in 0..<columns.length() {
      values.push(encode_value(row.value(i)))
    }
    encoded_rows.push(@json.Json::array(values))
  }
  let affected = rows.changes()
  let last_rowid = if affected > 0L {
    @json.Json::string(conn.last_insert_rowid().to_string())
  } else {
    @json.Json::null()
  }
  object([
    ("cols", @json.Json::array(encoded_columns)),
    (
      "rows",
      if want_rows {
        @json.Json::array(encoded_rows)
      } else {
        @json.Json::array([])
      },
    ),
    ("affected_row_count", @json.Json::number(affected.to_double())),
    ("last_insert_rowid", last_rowid),
    ("rows_read", @json.Json::number(0)),
    ("rows_written", @json.Json::number(affected.to_double())),
    ("query_duration_ms", @json.Json::number(0)),
  ])
}

///|
fn condition_is_true(
  condition : Map[String, @json.Json],
  results : Array[Bool?],
) -> Bool raise {
  let kind = match field(condition, "type") {
    Some(value) => as_string(value)
    None => raise Failure::Failure("condition.type is required")
  }
  match kind {
    "ok" => {
      let step = match field(condition, "step") {
        Some(@json.Json::Number(value, ..)) => value.to_int()
        _ => raise Failure::Failure("condition.step is required")
      }
      step >= 0 && step < results.length() && results[step] == Some(true)
    }
    "error" => {
      let step = match field(condition, "step") {
        Some(@json.Json::Number(value, ..)) => value.to_int()
        _ => raise Failure::Failure("condition.step is required")
      }
      step >= 0 && step < results.length() && results[step] != Some(true)
    }
    "not" => {
      let nested = match field(condition, "cond") {
        Some(value) => as_object(value)
        None => raise Failure::Failure("condition.cond is required")
      }
      !condition_is_true(nested, results)
    }
    "and" | "or" => {
      let conds = match field(condition, "conds") {
        Some(value) => as_array(value)
        None => raise Failure::Failure("condition.conds is required")
      }
      let mut matched = kind == "and"
      for cond in conds {
        let value = condition_is_true(as_object(cond), results)
        if kind == "and" && !value {
          matched = false
        } else if kind == "or" && value {
          matched = true
        }
      }
      matched
    }
    "is_autocommit" => true
    _ => raise Failure::Failure("unsupported condition type: \{kind}")
  }
}

///|
async fn execute_batch(
  conn : @mturso.Connection,
  batch : Map[String, @json.Json],
) -> @json.Json {
  let steps = match field(batch, "steps") {
    Some(value) => as_array(value)
    None => raise Failure::Failure("batch.steps is required")
  }
  let results : Array[Bool?] = []
  let step_results = []
  let step_errors = []
  for step in steps {
    let fields = as_object(step)
    let should_run = match field(fields, "condition") {
      Some(condition) => condition_is_true(as_object(condition), results)
      None => true
    }
    if !should_run {
      results.push(None)
      step_results.push(@json.Json::null())
      step_errors.push(@json.Json::null())
      continue
    }
    let stmt = match field(fields, "stmt") {
      Some(value) => as_object(value)
      None => raise Failure::Failure("batch step stmt is required")
    }
    try {
      let result = execute_statement(conn, stmt)
      results.push(Some(true))
      step_results.push(result)
      step_errors.push(@json.Json::null())
    } catch {
      error => {
        results.push(Some(false))
        step_results.push(@json.Json::null())
        step_errors.push(error_object("BATCH_STEP_ERROR", "\{error}"))
      }
    } noraise {
      _ => ()
    }
  }
  object([
    ("step_results", @json.Json::array(step_results)),
    ("step_errors", @json.Json::array(step_errors)),
  ])
}

///|
async fn process_request(
  conn : @mturso.Connection,
  request : @json.Json,
) -> @json.Json {
  let fields = try as_object(request) catch {
    error => return error_result(error_object("PROTOCOL_ERROR", "\{error}"))
  } noraise {
    value => value
  }
  let kind = match field(fields, "type") {
    Some(value) =>
      try as_string(value) catch {
        _ => return error_result(error_object("PROTOCOL_ERROR", "invalid type"))
      } noraise {
        value => value
      }
    None =>
      return error_result(error_object("UNKNOWN", "request.type is required"))
  }
  match kind {
    "execute" => {
      let stmt = match field(fields, "stmt") {
        Some(value) =>
          try as_object(value) catch {
            _ =>
              return error_result(
                error_object("PROTOCOL_ERROR", "invalid stmt"),
              )
          } noraise {
            value => value
          }
        None => return error_result(error_object("NO_STMT", "stmt is required"))
      }
      try ok_result("execute", execute_statement(conn, stmt)) catch {
        error => error_result(error_object("EXECUTE_ERROR", "\{error}"))
      } noraise {
        value => value
      }
    }
    "batch" => {
      let batch = match field(fields, "batch") {
        Some(value) =>
          try as_object(value) catch {
            _ =>
              return error_result(
                error_object("PROTOCOL_ERROR", "invalid batch"),
              )
          } noraise {
            value => value
          }
        None =>
          return error_result(error_object("NO_BATCH", "batch is required"))
      }
      try ok_result("batch", execute_batch(conn, batch)) catch {
        error => error_result(error_object("BATCH_ERROR", "\{error}"))
      } noraise {
        value => value
      }
    }
    "close" => ok_result("close", @json.Json::null())
    _ => error_result(error_object("UNKNOWN", "unknown request type: \{kind}"))
  }
}

///|
async fn handle_pipeline(
  db : @mturso.Database,
  conn : @http.ServerConnection,
) -> Unit {
  let body = try conn.read_all() catch {
    error => {
      conn.send_response(400, "Bad Request", extra_headers={
        "content-type": "application/json",
      })
      conn.text.write(error_response(400, "\{error}").stringify())
      return
    }
  } noraise {
    value => value
  }
  let request = try @json.parse(@utf8.decode_lossy(body)) catch {
    error => {
      conn.send_response(400, "Bad Request", extra_headers={
        "content-type": "application/json",
      })
      conn.text.write(error_response(400, "\{error}").stringify())
      return
    }
  } noraise {
    value => value
  }
  let fields = match request {
    @json.Json::Object(fields) => fields
    _ => {
      conn.send_response(400, "Bad Request", extra_headers={
        "content-type": "application/json",
      })
      conn.text.write(
        error_response(400, "request must be an object").stringify(),
      )
      return
    }
  }
  if field(fields, "baton") is Some(@json.Json::String(_)) {
    conn.send_response(400, "Bad Request", extra_headers={
      "content-type": "application/json",
    })
    conn.text.write(
      error_response(400, "streams and batons are not supported").stringify(),
    )
    return
  }
  let requests = match field(fields, "requests") {
    Some(@json.Json::Array(requests)) => requests
    _ => {
      conn.send_response(400, "Bad Request", extra_headers={
        "content-type": "application/json",
      })
      conn.text.write(
        error_response(400, "requests must be an array").stringify(),
      )
      return
    }
  }
  let session = try db.connect() catch {
    error => {
      conn.send_response(500, "Internal Server Error", extra_headers={
        "content-type": "application/json",
      })
      conn.text.write(error_response(500, @debug.to_string(error)).stringify())
      return
    }
  } noraise {
    value => value
  }
  defer session.close()
  let results = []
  for request in requests {
    results.push(process_request(session, request))
  }
  let response = object([
    ("baton", @json.Json::null()),
    ("base_url", @json.Json::null()),
    ("results", @json.Json::array(results)),
  ])
  conn.send_response(200, "OK", extra_headers={
    "content-type": "application/json",
  })
  conn.text.write(response.stringify())
}

///|
async fn handle_cursor(
  db : @mturso.Database,
  conn : @http.ServerConnection,
) -> Unit {
  let body = try conn.read_all() catch {
    error => {
      conn.send_response(400, "Bad Request", extra_headers={
        "content-type": "application/json",
      })
      conn.text.write(error_response(400, "\{error}").stringify())
      return
    }
  } noraise {
    value => value
  }
  let request = try @json.parse(@utf8.decode_lossy(body)) catch {
    error => {
      conn.send_response(400, "Bad Request", extra_headers={
        "content-type": "application/json",
      })
      conn.text.write(error_response(400, "\{error}").stringify())
      return
    }
  } noraise {
    value => value
  }
  let fields = match request {
    @json.Json::Object(fields) => fields
    _ => {
      conn.send_response(400, "Bad Request", extra_headers={
        "content-type": "application/json",
      })
      conn.text.write(
        error_response(400, "request must be an object").stringify(),
      )
      return
    }
  }
  if field(fields, "baton") is Some(@json.Json::String(_)) {
    conn.send_response(400, "Bad Request", extra_headers={
      "content-type": "application/json",
    })
    conn.text.write(
      error_response(400, "streams and batons are not supported").stringify(),
    )
    return
  }
  let batch = match field(fields, "batch") {
    Some(value) =>
      try as_object(value) catch {
        _ => {
          conn.send_response(400, "Bad Request", extra_headers={
            "content-type": "application/json",
          })
          conn.text.write(error_response(400, "invalid batch").stringify())
          return
        }
      } noraise {
        value => value
      }
    None => {
      conn.send_response(400, "Bad Request", extra_headers={
        "content-type": "application/json",
      })
      conn.text.write(error_response(400, "batch is required").stringify())
      return
    }
  }
  let steps = match field(batch, "steps") {
    Some(@json.Json::Array(steps)) => steps
    _ => {
      conn.send_response(400, "Bad Request", extra_headers={
        "content-type": "application/json",
      })
      conn.text.write(
        error_response(400, "batch.steps is required").stringify(),
      )
      return
    }
  }
  let session = try db.connect() catch {
    error => {
      conn.send_response(500, "Internal Server Error", extra_headers={
        "content-type": "application/json",
      })
      conn.text.write(error_response(500, @debug.to_string(error)).stringify())
      return
    }
  } noraise {
    value => value
  }
  defer session.close()
  let lines = StringBuilder()
  lines.write_string("{\"baton\":null,\"base_url\":null}\n")
  let results : Array[Bool?] = []
  for step_idx, step in steps {
    let step_fields = as_object(step) catch {
      _ => {
        results.push(None)
        continue
      }
    }
    let should_run = match field(step_fields, "condition") {
      Some(condition) => condition_is_true(as_object(condition), results)
      None => true
    }
    if !should_run {
      results.push(None)
      continue
    }
    let stmt = match field(step_fields, "stmt") {
      Some(value) => as_object(value)
      None => {
        results.push(None)
        continue
      }
    }
    let result = try execute_statement(session, stmt) catch {
      error => {
        results.push(Some(false))
        lines.write_string(
          object([
            ("type", @json.Json::string("step_error")),
            ("step", @json.Json::number(step_idx.to_double())),
            ("error", error_object("BATCH_STEP_ERROR", @debug.to_string(error))),
          ]).stringify(),
        )
        lines.write_string("\n")
        continue
      }
    } noraise {
      value => value
    }
    results.push(Some(true))
    let result_fields = as_object(result)
    let cols = match field(result_fields, "cols") {
      Some(value) => value
      None => @json.Json::array([])
    }
    lines.write_string(
      object([
        ("type", @json.Json::string("step_begin")),
        ("step", @json.Json::number(step_idx.to_double())),
        ("cols", cols),
      ]).stringify(),
    )
    lines.write_string("\n")
    let rows = match field(result_fields, "rows") {
      Some(@json.Json::Array(rows)) => rows
      _ => []
    }
    for row in rows {
      lines.write_string(
        object([("type", @json.Json::string("row")), ("row", row)]).stringify(),
      )
      lines.write_string("\n")
    }
    let affected = match field(result_fields, "affected_row_count") {
      Some(value) => value
      None => @json.Json::number(0)
    }
    let last_rowid = match field(result_fields, "last_insert_rowid") {
      Some(value) => value
      None => @json.Json::null()
    }
    lines.write_string(
      object([
        ("type", @json.Json::string("step_end")),
        ("affected_row_count", affected),
        ("last_insert_rowid", last_rowid),
      ]).stringify(),
    )
    lines.write_string("\n")
  }
  lines.write_string(
    "{\"type\":\"replication_index\",\"replication_index\":null}\n",
  )
  conn.send_response(200, "OK", extra_headers={
    "content-type": "application/x-ndjson",
  })
  conn.text.write(lines.to_string())
}

///|
async fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: mturso-native-server <database-path> [loopback-address]")
    @env.exit(1)
  }
  let database_path = args[1]
  let address = if args.length() >= 3 { args[2] } else { "127.0.0.1:8080" }
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
  let server = try @http.Server(@socket.Addr::parse(address)) catch {
    error => {
      println("failed to bind \{address}: \{error}")
      @env.exit(1)
    }
  } noraise {
    value => value
  }
  defer server.close()
  println("native sync server listening at http://\{server.addr}")
  server.run_forever(async fn(request, conn) {
    match (request.meth, request.path) {
      (@http.Post, "/v2/pipeline") | (@http.Post, "/v3/pipeline") =>
        handle_pipeline(db, conn)
      (@http.Post, "/v3/cursor") => handle_cursor(db, conn)
      (@http.Options, _) =>
        conn.send_response(204, "No Content", extra_headers={})
      _ => {
        conn.send_response(404, "Not Found", extra_headers={
          "content-type": "application/json",
        })
        conn.text.write(error_response(404, "Not Found").stringify())
      }
    }
  })
}
