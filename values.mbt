// 内置类型对 ToValue / FromValue / FromRow 的实例。
//
// 与 moonpg 的差别：Turso 没有 OID，所以「编码」就是直接构造 `Value`。

///|
/// 微秒级 UNIX 时间戳。存成 `Value::Integer`，读回时 `Integer` / `Real` 都能解。
///
/// 「类型即约定」：Turso 没有 timestamp 类型，约定用整数微秒表示。
pub(all) struct Timestamp(Int64) derive(Eq, Debug)

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
  @value.Value::Integer(self.0)
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
/// `Integer` / `Real` 都能解。
pub impl FromValue for Timestamp with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Integer(i) => Timestamp(i)
    @value.Value::Real(f) => Timestamp(f.to_int64())
    _ => raise ValueError::ValueError("expected Value::Integer for Timestamp")
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
