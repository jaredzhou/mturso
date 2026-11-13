///|
/// Framework-independent HTTP payload returned by the native sync server.
pub(all) struct NativeHttpResponse {
  status : Int
  content_type : String
  body : String
}

///|
fn native_error_response(
  status : Int,
  message : String,
) -> NativeHttpResponse {
  {
    status,
    content_type: "application/json",
    body: error_response(status, message).stringify(),
  }
}

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
fn sqlite_error_object(code : String, message : String) -> @json.Json {
  error_object(code, message)
}

///|
fn query_error_object(message : String) -> @json.Json {
  let code = if message.contains("constraint failed") {
    "SQLITE_CONSTRAINT"
  } else if message.contains("no such table") ||
    message.contains("Parse error") ||
    message.contains("syntax error") {
    "SQL_PARSE_ERROR"
  } else {
    "SQLITE_ERROR"
  }
  sqlite_error_object(code, message)
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
fn field(fields : Map[String, @json.Json], name : String) -> @json.Json? {
  fields.get(name)
}

///|
fn encode_value(value : @mturso.Value) -> @json.Json {
  @json.ToJson::to_json(
    match value {
      @mturso.Value::Null => HranaValue::Null
      @mturso.Value::Integer(value) => HranaValue::Integer(value)
      @mturso.Value::Real(value) => HranaValue::Real(value)
      @mturso.Value::Text(value) => HranaValue::Text(value)
      @mturso.Value::Blob(value) => HranaValue::Blob(value)
    },
  )
}

///|
fn decode_args(stmt : HranaStmt) -> Array[@mturso.Value] raise {
  let args = match stmt.args {
    Some(args) => args
    None => []
  }
  let values = []
  for arg in args {
    values.push(
      match arg {
        HranaValue::Null => @mturso.Value::Null
        HranaValue::Integer(value) => @mturso.Value::Integer(value)
        HranaValue::Real(value) => @mturso.Value::Real(value)
        HranaValue::Text(value) => @mturso.Value::Text(value)
        HranaValue::Blob(value) => @mturso.Value::Blob(value)
      },
    )
  }
  if stmt.named_args is Some(named) && !named.is_empty() {
    raise Failure::Failure("named_args are not supported")
  }
  values
}

///|
async fn execute_statement(
  conn : @mturso.Connection,
  stmt : HranaStmt,
) -> @json.Json {
  let sql = match stmt.sql {
    Some(sql) => sql
    None => raise Failure::Failure("No SQL provided")
  }
  let args = decode_args(stmt)
  let want_rows = match stmt.want_rows {
    Some(value) => value
    None => true
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
  conn : @mturso.Connection,
  condition : HranaBatchCondition,
  results : Array[Bool?],
) -> Bool raise {
  match condition {
    Ok(step) =>
      step >= 0 && step < results.length() && results[step] == Some(true)
    Error(step) =>
      step >= 0 && step < results.length() && results[step] != Some(true)
    Not(nested) => !condition_is_true(conn, nested, results)
    And(conds) => {
      let mut matched = true
      for cond in conds {
        if !condition_is_true(conn, cond, results) {
          matched = false
        }
      }
      matched
    }
    Or(conds) => {
      let mut matched = false
      for cond in conds {
        if condition_is_true(conn, cond, results) {
          matched = true
        }
      }
      matched
    }
    IsAutocommit => conn.autocommit()
    Unknown(kind) =>
      raise Failure::Failure("unsupported condition type: \{kind}")
  }
}

///|
async fn execute_batch(
  conn : @mturso.Connection,
  batch : HranaBatch,
) -> @json.Json {
  let steps = batch.steps
  let results : Array[Bool?] = []
  let step_results = []
  let step_errors = []
  for step in steps {
    let should_run = match step.condition {
      Some(condition) => condition_is_true(conn, condition, results)
      None => true
    }
    if !should_run {
      results.push(None)
      step_results.push(@json.Json::null())
      step_errors.push(@json.Json::null())
      continue
    }
    let stmt = step.stmt
    try {
      let result = execute_statement(conn, stmt)
      results.push(Some(true))
      step_results.push(result)
      step_errors.push(@json.Json::null())
    } catch {
      error => {
        results.push(Some(false))
        step_results.push(@json.Json::null())
        step_errors.push(
          match error {
            @mturso.TursoError::QueryError(message) =>
              query_error_object(message)
            @mturso.TursoError::Busy(message) =>
              sqlite_error_object("SQLITE_BUSY", message)
            @mturso.TursoError::Conflict(message) =>
              sqlite_error_object("SQLITE_BUSY_SNAPSHOT", message)
            @mturso.TursoError::ConnectionError(message) =>
              sqlite_error_object("SQLITE_CANTOPEN", message)
            @mturso.TursoError::SyncError(_, message) =>
              sqlite_error_object("SQLITE_ERROR", message)
            _ => error_object("BATCH_STEP_ERROR", @debug.to_string(error))
          },
        )
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
  request : PipelineCommand,
) -> @json.Json {
  match request {
    Execute(stmt) =>
      ok_result("execute", execute_statement(conn, stmt)) catch {
        error =>
          error_result(
            match error {
              @mturso.TursoError::QueryError(message) =>
                query_error_object(message)
              @mturso.TursoError::Busy(message) =>
                sqlite_error_object("SQLITE_BUSY", message)
              @mturso.TursoError::Conflict(message) =>
                sqlite_error_object("SQLITE_BUSY_SNAPSHOT", message)
              @mturso.TursoError::ConnectionError(message) =>
                sqlite_error_object("SQLITE_CANTOPEN", message)
              @mturso.TursoError::SyncError(_, message) =>
                sqlite_error_object("SQLITE_ERROR", message)
              _ => error_object("EXECUTE_ERROR", @debug.to_string(error))
            },
          )
      }
    Batch(batch) =>
      ok_result("batch", execute_batch(conn, batch)) catch {
        error => error_result(error_object("BATCH_ERROR", "\{error}"))
      }
    Close => ok_result("close", @json.Json::null())
    Unknown(kind) =>
      error_result(error_object("UNKNOWN", "unknown request type: \{kind}"))
  }
}

///|
pub async fn process_pipeline_request(
  db : @mturso.Database,
  request : PipelineRequest,
) -> NativeHttpResponse {
  if request.baton is Some(_) {
    return native_error_response(400, "streams and batons are not supported")
  }
  let session = db.connect() catch {
    error => return native_error_response(500, @debug.to_string(error))
  }
  defer session.close()
  let results = []
  for command in request.requests {
    results.push(process_request(session, command))
  }
  let response = object([
    ("baton", @json.Json::null()),
    ("base_url", @json.Json::null()),
    ("results", @json.Json::array(results)),
  ])
  { status: 200, content_type: "application/json", body: response.stringify(), }
}

///|
pub async fn process_cursor_request(
  db : @mturso.Database,
  request : CursorRequest,
) -> NativeHttpResponse {
  if request.baton is Some(_) {
    return native_error_response(400, "streams and batons are not supported")
  }
  let steps = request.batch.steps
  let session = db.connect() catch {
    error => return native_error_response(500, @debug.to_string(error))
  }
  defer session.close()
  let lines = StringBuilder()
  lines.write_string("{\"baton\":null,\"base_url\":null}\n")
  let results : Array[Bool?] = []
  for step_idx, step in steps {
    let should_run = match step.condition {
      Some(condition) => condition_is_true(session, condition, results)
      None => true
    }
    if !should_run {
      results.push(None)
      continue
    }
    let result = execute_statement(session, step.stmt) catch {
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
  {
    status: 200,
    content_type: "application/x-ndjson",
    body: lines.to_string(),
  }
}
