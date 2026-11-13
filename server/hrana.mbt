// Typed subset of the Hrana request model used by the native server.

///|
pub struct PipelineRequest {
  priv baton : String?
  priv requests : Array[PipelineCommand]
}

///|
pub struct CursorRequest {
  priv baton : String?
  priv batch : HranaBatch
}

///|
priv struct HranaStmt {
  sql : String?
  args : Array[HranaValue]?
  named_args_present : Bool
  want_rows : Bool?
}

///|
priv struct HranaBatch {
  steps : Array[HranaBatchStep]
}

///|
priv struct HranaBatchStep {
  condition : HranaBatchCondition?
  stmt : HranaStmt
}

///|
priv enum PipelineCommand {
  Execute(HranaStmt)
  Batch(HranaBatch)
  Close
  Unknown(String)
}

///|
priv enum HranaBatchCondition {
  Ok(Int)
  Error(Int)
  Not(HranaBatchCondition)
  And(Array[HranaBatchCondition])
  Or(Array[HranaBatchCondition])
  IsAutocommit
  Unknown(String)
}

///|
priv enum HranaValue {
  Null
  Integer(Int64)
  Real(Double)
  Text(String)
  Blob(Bytes)
}

///|
fn[T] decode_error(
  path : @json.JsonPath,
  message : String,
) -> T raise @json.JsonDecodeError {
  raise @json.JsonDecodeError((path, message))
}

///|
fn request_object(
  json : @json.Json,
  path : @json.JsonPath,
) -> Map[String, @json.Json] raise @json.JsonDecodeError {
  match json {
    @json.Json::Object(fields) => fields
    _ => decode_error(path, "expected JSON object")
  }
}

///|
fn[T : @json.FromJson] required_field(
  fields : Map[String, @json.Json],
  name : String,
  path : @json.JsonPath,
) -> T raise @json.JsonDecodeError {
  match fields.get(name) {
    Some(value) => @json.from_json(value, path=path.add_key(name))
    None => decode_error(path, "missing field: \{name}")
  }
}

///|
fn[T : @json.FromJson] optional_field(
  fields : Map[String, @json.Json],
  name : String,
  path : @json.JsonPath,
) -> T? raise @json.JsonDecodeError {
  match fields.get(name) {
    Some(@json.Json::Null) | None => None
    Some(value) => Some(@json.from_json(value, path=path.add_key(name)))
  }
}

///|
pub impl @json.FromJson for PipelineRequest with fn from_json(
  json : @json.Json,
  path : @json.JsonPath,
) -> PipelineRequest raise @json.JsonDecodeError {
  let fields = request_object(json, path)
  {
    baton: optional_field(fields, "baton", path),
    requests: required_field(fields, "requests", path),
  }
}

///|
pub extend PipelineRequest with @json.FromJson::{from_json}

///|
pub impl @json.FromJson for CursorRequest with fn from_json(
  json : @json.Json,
  path : @json.JsonPath,
) -> CursorRequest raise @json.JsonDecodeError {
  let fields = request_object(json, path)
  {
    baton: optional_field(fields, "baton", path),
    batch: required_field(fields, "batch", path),
  }
}

///|
pub extend CursorRequest with @json.FromJson::{from_json}

///|
impl @json.FromJson for HranaStmt with fn from_json(
  json : @json.Json,
  path : @json.JsonPath,
) -> HranaStmt raise @json.JsonDecodeError {
  let fields = request_object(json, path)
  let named_args : Array[@json.Json]? = optional_field(
    fields, "named_args", path,
  )
  {
    sql: optional_field(fields, "sql", path),
    args: optional_field(fields, "args", path),
    named_args_present: named_args is Some(args) && !args.is_empty(),
    want_rows: optional_field(fields, "want_rows", path),
  }
}

///|
impl @json.FromJson for HranaBatch with fn from_json(
  json : @json.Json,
  path : @json.JsonPath,
) -> HranaBatch raise @json.JsonDecodeError {
  let fields = request_object(json, path)
  { steps: required_field(fields, "steps", path), }
}

///|
impl @json.FromJson for HranaBatchStep with fn from_json(
  json : @json.Json,
  path : @json.JsonPath,
) -> HranaBatchStep raise @json.JsonDecodeError {
  let fields = request_object(json, path)
  {
    condition: optional_field(fields, "condition", path),
    stmt: required_field(fields, "stmt", path),
  }
}

///|
impl @json.FromJson for PipelineCommand with fn from_json(
  json : @json.Json,
  path : @json.JsonPath,
) -> PipelineCommand raise @json.JsonDecodeError {
  let fields = request_object(json, path)
  let kind : String = required_field(fields, "type", path)
  match kind {
    "execute" => PipelineCommand::Execute(required_field(fields, "stmt", path))
    "batch" => PipelineCommand::Batch(required_field(fields, "batch", path))
    "close" => PipelineCommand::Close
    _ => PipelineCommand::Unknown(kind)
  }
}

///|
impl @json.FromJson for HranaBatchCondition with fn from_json(
  json : @json.Json,
  path : @json.JsonPath,
) -> HranaBatchCondition raise @json.JsonDecodeError {
  let fields = request_object(json, path)
  let kind : String = required_field(fields, "type", path)
  match kind {
    "ok" => HranaBatchCondition::Ok(required_field(fields, "step", path))
    "error" => HranaBatchCondition::Error(required_field(fields, "step", path))
    "not" => HranaBatchCondition::Not(required_field(fields, "cond", path))
    "and" => HranaBatchCondition::And(required_field(fields, "conds", path))
    "or" => HranaBatchCondition::Or(required_field(fields, "conds", path))
    "is_autocommit" => HranaBatchCondition::IsAutocommit
    _ => HranaBatchCondition::Unknown(kind)
  }
}

///|
impl @json.FromJson for HranaValue with fn from_json(
  json : @json.Json,
  path : @json.JsonPath,
) -> HranaValue raise @json.JsonDecodeError {
  let fields = request_object(json, path)
  let kind : String = required_field(fields, "type", path)
  match kind {
    "null" => HranaValue::Null
    "integer" => {
      let raw : String = required_field(fields, "value", path)
      let value = @string.parse_int64(raw) catch {
        _ => decode_error(path, "invalid integer value: \{raw}")
      }
      HranaValue::Integer(value)
    }
    "float" =>
      match fields.get("value") {
        Some(@json.Json::Number(value, ..)) => HranaValue::Real(value)
        Some(@json.Json::Null) | None => HranaValue::Real(0.0 / 0.0)
        _ => decode_error(path, "invalid float value")
      }
    "text" => HranaValue::Text(required_field(fields, "value", path))
    "blob" => {
      let raw : String = required_field(fields, "base64", path)
      let value = @base64.decode(raw) catch {
        _ => decode_error(path, "invalid base64 blob")
      }
      HranaValue::Blob(value)
    }
    _ => decode_error(path, "unknown value type: \{kind}")
  }
}

///|
impl @json.ToJson for HranaValue with fn to_json(self : HranaValue) {
  match self {
    Null => @json.Json::object({ "type": @json.Json::string("null") })
    Integer(value) =>
      @json.Json::object({
        "type": @json.Json::string("integer"),
        "value": @json.Json::string(value.to_string()),
      })
    Real(value) =>
      @json.Json::object({
        "type": @json.Json::string("float"),
        "value": if value.is_nan() || value.is_inf() {
          @json.Json::null()
        } else {
          @json.Json::number(value)
        },
      })
    Text(value) =>
      @json.Json::object({
        "type": @json.Json::string("text"),
        "value": @json.Json::string(value),
      })
    Blob(value) =>
      @json.Json::object({
        "type": @json.Json::string("blob"),
        "base64": @json.Json::string(@base64.encode(value, padding=false)),
      })
  }
}
