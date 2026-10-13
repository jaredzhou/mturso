// 内置类型对 ToValue / FromValue / FromRow 的实例。
//
// 与 moonpg 的差别：Turso 没有 OID，所以「编码」就是直接构造 `Value`。

///|
/// ISO 8601 时间戳（UTC），例如 `"2026-10-13T00:00:00Z"`。
///
/// 与 Turso 内建的 `timestamp` custom type 对齐：那个类型的 base 是 **TEXT**
/// （ISO 8601），不是整数（见 docs.turso.tech/sql-reference/data-types）。
/// 要数值就走 `unix()`（秒）/ `Timestamp::from_unix()`。
pub(all) struct Timestamp(String) derive(Eq, Debug)

// ---------------------------------------------------------------------------
// ISO 8601 ↔ UNIX 秒（UTC）。用 Howard Hinnant 的 civil↔days 算法。
// ---------------------------------------------------------------------------

///|
fn days_from_civil(y : Int, m : Int, d : Int) -> Int {
  let yy = if m <= 2 { y - 1 } else { y }
  let era = (if yy >= 0 { yy } else { yy - 399 }) / 400
  let yoe = yy - era * 400
  let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468
}

///|
fn civil_from_days(z : Int) -> (Int, Int, Int) {
  let zz = z + 719468
  let era = (if zz >= 0 { zz } else { zz - 146096 }) / 146097
  let doe = zz - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  (if m <= 2 { y + 1 } else { y }, m, d)
}

///|
fn zero_pad(v : Int, width : Int) -> String {
  let s = v.to_string()
  let mut out = ""
  for _ in 0..<(width - s.length()) {
    out = out + "0"
  }
  out + s
}

///|
fn parse_digits(s : String, start : Int, len : Int) -> Int raise ValueError {
  let mut v = 0
  for i in 0..<len {
    let c = s[start + i].to_int()
    if c < 48 || c > 57 {
      raise ValueError::ValueError("bad digit in timestamp: \{s}")
    }
    v = v * 10 + (c - 48)
  }
  v
}

///|
/// 从 UNIX 秒（UTC）构造，格式化成 `YYYY-MM-DDTHH:MM:SSZ`。
pub fn Timestamp::from_unix(secs : Int64) -> Timestamp {
  let days = secs / 86400L
  let rem = secs % 86400L
  let d = if rem < 0L { days - 1L } else { days }
  let sod = if rem < 0L { rem + 86400L } else { rem }
  let (y, m, day) = civil_from_days(d.to_int())
  let hh = (sod / 3600L).to_int()
  let mi = ((sod % 3600L) / 60L).to_int()
  let ss = (sod % 60L).to_int()
  let ymd = "\{zero_pad(y, 4)}-\{zero_pad(m, 2)}-\{zero_pad(day, 2)}"
  let hms = "\{zero_pad(hh, 2)}:\{zero_pad(mi, 2)}:\{zero_pad(ss, 2)}"
  Timestamp("\{ymd}T\{hms}Z")
}

///|
/// 取 UNIX 秒（UTC）。接受 `YYYY-MM-DD[T ]HH:MM:SS`，后面可跟 `Z` 或 `.小数`；
/// 别的形式（比如带时区偏移 `+08:00`）抛 `ValueError`。
pub fn Timestamp::unix(self : Timestamp) -> Int64 raise ValueError {
  let s = self.0
  let n = s.length()
  let suffix_ok = n == 19 || (n > 19 && (s[19] == 'Z' || s[19] == '.'))
  if n < 19 ||
    !suffix_ok ||
    s[4] != '-' ||
    s[7] != '-' ||
    (s[10] != 'T' && s[10] != ' ') ||
    s[13] != ':' ||
    s[16] != ':' {
    raise ValueError::ValueError(
      "expected ISO 8601 'YYYY-MM-DDTHH:MM:SS[Z]', got: \{s}",
    )
  }
  let y = parse_digits(s, 0, 4)
  let mo = parse_digits(s, 5, 2)
  let d = parse_digits(s, 8, 2)
  let hh = parse_digits(s, 11, 2)
  let mi = parse_digits(s, 14, 2)
  let ss = parse_digits(s, 17, 2)
  let days = days_from_civil(y, mo, d)
  days.to_int64() * 86400L + hh.to_int64() * 3600L + mi.to_int64() * 60L + ss.to_int64()
}

// ---------------------------------------------------------------------------
// ToValue：SQL 参数
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Bool with fn to_value(self) {
  @value.Value::Integer(if self { 1L } else { 0L })
}

///|
pub impl ToValue for Int with fn to_value(self) {
  @value.Value::Integer(self.to_int64())
}

///|
pub impl ToValue for Int64 with fn to_value(self) {
  @value.Value::Integer(self)
}

///|
pub impl ToValue for Double with fn to_value(self) {
  @value.Value::Real(self)
}

///|
pub impl ToValue for String with fn to_value(self) {
  @value.Value::Text(self)
}

///|
pub impl ToValue for Bytes with fn to_value(self) {
  @value.Value::Blob(self)
}

///|
/// 已经是 `Value` 的直接透传（方便「有时要显式给 NULL」的场景）。
pub impl ToValue for @value.Value with fn to_value(self) {
  self
}

///|
/// `None` → `Value::Null`。
pub impl[T : ToValue] ToValue for T? with fn to_value(self) {
  match self {
    None => @value.Value::Null
    Some(v) => v.to_value()
  }
}

///|
pub impl ToValue for Timestamp with fn to_value(self) {
  @value.Value::Text(self.0)
}

///|
pub impl ToValue for Json with fn to_value(self) {
  @value.Value::Text(self.stringify())
}

// ---------------------------------------------------------------------------
// FromValue：从一列里解出值
// ---------------------------------------------------------------------------

///|
pub impl FromValue for Bool with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Integer(i) => i != 0L
    _ => raise ValueError::ValueError("expected Value::Integer for Bool")
  }
}

///|
pub impl FromValue for Int with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Integer(i) => i.to_int()
    _ => raise ValueError::ValueError("expected Value::Integer")
  }
}

///|
pub impl FromValue for Int64 with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Integer(i) => i
    _ => raise ValueError::ValueError("expected Value::Integer")
  }
}

///|
pub impl FromValue for Double with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Real(f) => f
    _ => raise ValueError::ValueError("expected Value::Real")
  }
}

///|
/// `Value::Text` / `Value::Blob` 都按 UTF-8 解析（宽松解码不会产生问题，
/// 但真的想严格，就用 `Row::value_raw` 自己解）。
pub impl FromValue for String with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Text(s) => s
    @value.Value::Blob(b) => @utf8.decode_lossy(b)
    _ => raise ValueError::ValueError("expected Value::Text or Value::Blob")
  }
}

///|
pub impl FromValue for Bytes with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Blob(b) => b
    _ => raise ValueError::ValueError("expected Value::Blob")
  }
}

///|
pub impl[T : FromValue] FromValue for T? with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Null => None
    _ => Some(T::from_value(v))
  }
}

///|
/// 只认 `Value::Text`（ISO 8601），与 Turso 内建 `timestamp` 的 base 一致。
pub impl FromValue for Timestamp with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Text(s) => Timestamp(s)
    _ => raise ValueError::ValueError("expected Value::Text (ISO 8601) for Timestamp")
  }
}

///|
pub impl FromValue for Json with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Text(s) =>
      @json.parse(s) catch {
        _ => raise ValueError::ValueError("invalid JSON text")
      }
    _ => raise ValueError::ValueError("expected Value::Text for Json")
  }
}

// ---------------------------------------------------------------------------
// FromRow：整行映射
// ---------------------------------------------------------------------------

///|
pub impl FromRow for Bool with fn from_row(r : Row) -> Bool raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for Int with fn from_row(r : Row) -> Int raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for Int64 with fn from_row(r : Row) -> Int64 raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for Double with fn from_row(r : Row) -> Double raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for String with fn from_row(r : Row) -> String raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for Bytes with fn from_row(r : Row) -> Bytes raise TursoError {
  r.get(0)
}

///|
pub impl[T : FromValue] FromRow for T? with fn from_row(r : Row) -> T? raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for Timestamp with fn from_row(r : Row) -> Timestamp raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for Json with fn from_row(r : Row) -> Json raise TursoError {
  r.get(0)
}

///|
/// 元组按列顺序映射（`fetch[(Int, String)]`）。
pub impl[A : FromValue, B : FromValue] FromRow for (A, B) with fn from_row(
  r : Row,
) -> (A, B) raise TursoError {
  (r.get(0), r.get(1))
}

///|
pub impl[A : FromValue, B : FromValue, C : FromValue] FromRow for (A, B, C) with fn from_row(
  r : Row,
) -> (A, B, C) raise TursoError {
  (r.get(0), r.get(1), r.get(2))
}

///|
pub impl[A : FromValue, B : FromValue, C : FromValue, D : FromValue] FromRow for (
  A,
  B,
  C,
  D,
) with fn from_row(r : Row) -> (A, B, C, D) raise TursoError {
  (r.get(0), r.get(1), r.get(2), r.get(3))
}

///|
pub impl[
  A : FromValue,
  B : FromValue,
  C : FromValue,
  D : FromValue,
  E : FromValue,
] FromRow for (A, B, C, D, E) with fn from_row(r : Row) -> (A, B, C, D, E) raise TursoError {
  (r.get(0), r.get(1), r.get(2), r.get(3), r.get(4))
}

// ---------------------------------------------------------------------------
// 更宽的整数族 / 浮点 / 字符 / Unit / Ref
//
// Turso 存储层只有一种整数（`Value::Integer`），所以各宽度整数都落到它；读出时
// 再做窄化（用 core 的 `to_*` 语义，和 moonpg 一致）。
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Byte with fn to_value(self) {
  @value.Value::Integer(self.to_int64())
}

///|
pub impl ToValue for Int16 with fn to_value(self) {
  @value.Value::Integer(self.to_int64())
}

///|
pub impl ToValue for UInt with fn to_value(self) {
  @value.Value::Integer(self.reinterpret_as_int().to_int64())
}

///|
pub impl ToValue for UInt16 with fn to_value(self) {
  @value.Value::Integer(self.to_int64())
}

///|
pub impl ToValue for UInt64 with fn to_value(self) {
  @value.Value::Integer(self.reinterpret_as_int64())
}

///|
pub impl ToValue for Float with fn to_value(self) {
  @value.Value::Real(self.to_double())
}

///|
pub impl ToValue for Char with fn to_value(self) {
  @value.Value::Text(self.to_string())
}

///|
/// `()` → `Value::Null`。
pub impl ToValue for Unit with fn to_value(_self) {
  @value.Value::Null
}

///|
/// `Ref[T]` 解引用后照常编码。
pub impl[T : ToValue] ToValue for Ref[T] with fn to_value(self) {
  self.val.to_value()
}

///|
pub impl FromValue for Byte with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Integer(i) => i.to_byte()
    _ => raise ValueError::ValueError("expected Value::Integer for Byte")
  }
}

///|
pub impl FromValue for Int16 with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Integer(i) => Int16::from_int(i.to_int())
    _ => raise ValueError::ValueError("expected Value::Integer for Int16")
  }
}

///|
pub impl FromValue for UInt with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Integer(i) => i.to_int().reinterpret_as_uint()
    _ => raise ValueError::ValueError("expected Value::Integer for UInt")
  }
}

///|
pub impl FromValue for UInt16 with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Integer(i) => i.to_uint16()
    _ => raise ValueError::ValueError("expected Value::Integer for UInt16")
  }
}

///|
pub impl FromValue for UInt64 with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Integer(i) => i.reinterpret_as_uint64()
    _ => raise ValueError::ValueError("expected Value::Integer for UInt64")
  }
}

///|
pub impl FromValue for Float with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Real(f) => Float::from_double(f)
    _ => raise ValueError::ValueError("expected Value::Real for Float")
  }
}

///|
/// 只接受恰好一个字符的 `Value::Text`。
pub impl FromValue for Char with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Text(s) =>
      match s.get_char(0) {
        Some(c) if s.length() == 1 => c
        _ => raise ValueError::ValueError("expected a single-char Value::Text")
      }
    _ => raise ValueError::ValueError("expected Value::Text for Char")
  }
}

///|
pub impl[T : FromValue] FromValue for Ref[T] with fn from_value(
  v : @value.Value,
) {
  Ref(T::from_value(v))
}

// ---------------------------------------------------------------------------
// JSON 族：Array / Map —— 一律落成 **JSON 文本**（`Value::Text`）。
//
// JSONB（BLOB）在当前绑定层做不了：那套二进制是引擎内部的
// （`core/json/jsonb.rs`），绑定层拼不出来，只能在 SQL 里 `jsonb(?1)` 让引擎转；
// 读回来同理（`json(col)`）。
// ---------------------------------------------------------------------------

///|
pub impl[T : @json.ToJson] ToValue for Array[T] with fn to_value(self) {
  @value.Value::Text(@json.to_json(self).stringify())
}

///|
pub impl[V : @json.ToJson] ToValue for Map[String, V] with fn to_value(self) {
  @value.Value::Text(@json.to_json(self).stringify())
}

///|
pub impl[T : @json.FromJson] FromValue for Array[T] with fn from_value(
  v : @value.Value,
) {
  match v {
    @value.Value::Text(s) => {
      let j = @json.parse(s) catch {
        _ => raise ValueError::ValueError("invalid JSON text")
      }
      @json.from_json(j) catch {
        _ => raise ValueError::ValueError("cannot decode JSON as Array")
      }
    }
    _ => raise ValueError::ValueError("expected Value::Text for Array")
  }
}

///|
pub impl[V : @json.FromJson] FromValue for Map[String, V] with fn from_value(
  v : @value.Value,
) {
  match v {
    @value.Value::Text(s) => {
      let j = @json.parse(s) catch {
        _ => raise ValueError::ValueError("invalid JSON text")
      }
      @json.from_json(j) catch {
        _ => raise ValueError::ValueError("cannot decode JSON as Map")
      }
    }
    _ => raise ValueError::ValueError("expected Value::Text for Map")
  }
}

// ---------------------------------------------------------------------------
// 上面这些的 FromRow（单列整行）
// ---------------------------------------------------------------------------

///|
pub impl FromRow for Byte with fn from_row(r : Row) -> Byte raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for Int16 with fn from_row(r : Row) -> Int16 raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for UInt with fn from_row(r : Row) -> UInt raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for UInt16 with fn from_row(r : Row) -> UInt16 raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for UInt64 with fn from_row(r : Row) -> UInt64 raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for Float with fn from_row(r : Row) -> Float raise TursoError {
  r.get(0)
}

///|
pub impl FromRow for Char with fn from_row(r : Row) -> Char raise TursoError {
  r.get(0)
}

///|
pub impl[T : FromValue] FromRow for Ref[T] with fn from_row(r : Row) -> Ref[T] raise TursoError {
  r.get(0)
}

///|
pub impl[T : @json.FromJson] FromRow for Array[T] with fn from_row(r : Row) -> Array[
  T,
] raise TursoError {
  r.get(0)
}

///|
pub impl[V : @json.FromJson] FromRow for Map[String, V] with fn from_row(
  r : Row,
) -> Map[String, V] raise TursoError {
  r.get(0)
}
