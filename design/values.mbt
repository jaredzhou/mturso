// 设计稿：内置类型对 ToValue / FromValue / FromRow 的实例。
//
// 与 moonpg 的差别：这里没有 OID → codec 这一层（Turso 没有 OID），
// 所以「编码」就是直接构造 `Value`。

// ---------------------------------------------------------------------------
// ToValue：SQL 参数
// ---------------------------------------------------------------------------

///|
declare pub impl ToValue for Bool

///|
declare pub impl ToValue for Int

///|
declare pub impl ToValue for Int64

///|
declare pub impl ToValue for Double

///|
declare pub impl ToValue for String

///|
declare pub impl ToValue for Bytes

///|
/// 已经是 `Value` 的直接透传（方便「有时要显式给 NULL」的场景）。
declare pub impl ToValue for @value.Value

///|
/// `None` → `Value::Null`。
declare pub impl[T : ToValue] ToValue for T?

///|
declare pub impl ToValue for Json

// ---------------------------------------------------------------------------
// 更宽的整数族 / 浮点 / 字符 / Unit / Ref（实现见根包 values.mbt）
// ---------------------------------------------------------------------------

///|
declare pub impl ToValue for Byte

///|
declare pub impl ToValue for Int16

///|
declare pub impl ToValue for UInt

///|
declare pub impl ToValue for UInt16

///|
declare pub impl ToValue for UInt64

///|
declare pub impl ToValue for Float

///|
declare pub impl ToValue for Char

///|
declare pub impl ToValue for Unit

///|
declare pub impl[T : ToValue] ToValue for Ref[T]

// ---------------------------------------------------------------------------
// FromValue：从一列里解出值
// ---------------------------------------------------------------------------

///|
declare pub impl FromValue for Bool

///|
declare pub impl FromValue for Int

///|
declare pub impl FromValue for Int64

///|
declare pub impl FromValue for Double

///|
/// `Value::Text` / `Value::Blob` 都按 UTF-8 解析（宽松解码不会产生问题，
/// 但真的想严格，就用 `Row::value_raw` 自己解）。
declare pub impl FromValue for String

///|
declare pub impl FromValue for Bytes

///|
declare pub impl[T : FromValue] FromValue for T?

///|
declare pub impl FromValue for Json

// ---------------------------------------------------------------------------
// FromRow：整行映射
// ---------------------------------------------------------------------------

///|
declare pub impl FromRow for Bool

///|
declare pub impl FromRow for Int

///|
declare pub impl FromRow for Int64

///|
declare pub impl FromRow for Double

///|
declare pub impl FromRow for String

///|
declare pub impl FromRow for Bytes

///|
declare pub impl[T : FromValue] FromRow for T?

///|
declare pub impl FromRow for Json

///|
/// 元组按列顺序映射（`fetch[(Int, String)]`）。
declare pub impl[A : FromValue, B : FromValue] FromRow for (A, B)

///|
declare pub impl[A : FromValue, B : FromValue, C : FromValue] FromRow for (
  A,
  B,
  C,
)

///|
declare pub impl[A : FromValue, B : FromValue, C : FromValue, D : FromValue] FromRow for (
  A,
  B,
  C,
  D,
)

///|
declare pub impl[
  A : FromValue,
  B : FromValue,
  C : FromValue,
  D : FromValue,
  E : FromValue,
] FromRow for (A, B, C, D, E)

// ---------------------------------------------------------------------------
// 便利类型
// ---------------------------------------------------------------------------

///|
/// ISO 8601 时间戳（UTC），例如 `"2026-10-13T00:00:00Z"`。
///
/// 与 Turso 内建的 `timestamp` custom type 对齐 —— 那个类型的 base 是 **TEXT**
/// （ISO 8601），不是整数（见 docs.turso.tech/sql-reference/data-types）。
/// 要数值走 `unix()`（秒）/ `Timestamp::from_unix()`。
pub(all) struct Timestamp(String) derive(Eq, Debug)

///|
/// 从 UNIX 秒（UTC）构造，格式化成 `YYYY-MM-DDTHH:MM:SSZ`。
declare pub fn Timestamp::from_unix(secs : Int64) -> Timestamp

///|
/// 取 UNIX 秒（UTC）。接受 `YYYY-MM-DD[T ]HH:MM:SS`，后面可跟 `Z` 或 `.小数`；
/// 别的形式（比如带时区偏移）抛 `ValueError`。
declare pub fn Timestamp::unix(self : Timestamp) -> Int64 raise ValueError

///|
declare pub impl ToValue for Timestamp

///|
declare pub impl FromValue for Timestamp

///|
declare pub impl FromRow for Timestamp

// ---------------------------------------------------------------------------
// 更宽的整数族 / 浮点 / 字符 / Unit / Ref：FromValue 侧
// ---------------------------------------------------------------------------

///|
declare pub impl FromValue for Byte

///|
declare pub impl FromValue for Int16

///|
declare pub impl FromValue for UInt

///|
declare pub impl FromValue for UInt16

///|
declare pub impl FromValue for UInt64

///|
declare pub impl FromValue for Float

///|
declare pub impl FromValue for Char

///|
declare pub impl[T : FromValue] FromValue for Ref[T]

// ---------------------------------------------------------------------------
// 更宽的整数族 / 浮点 / 字符 / Ref：FromRow 侧
// ---------------------------------------------------------------------------

///|
declare pub impl FromRow for Byte

///|
declare pub impl FromRow for Int16

///|
declare pub impl FromRow for UInt

///|
declare pub impl FromRow for UInt16

///|
declare pub impl FromRow for UInt64

///|
declare pub impl FromRow for Float

///|
declare pub impl FromRow for Char

///|
declare pub impl[T : FromValue] FromRow for Ref[T]

// ---------------------------------------------------------------------------
// JSON 族：`Array` / `Map` —— 一律落成 **JSON 文本**（`Value::Text`）。
//
// JSONB（BLOB）在绑定层做不了（字节格式是引擎内部的，见 core/json/jsonb.rs），
// 只能在 SQL 里 `jsonb(?1)` / `json(col)` 让引擎转。
// ---------------------------------------------------------------------------

///|
declare pub impl[T : @json.ToJson] ToValue for Array[T]

///|
declare pub impl[V : @json.ToJson] ToValue for Map[String, V]

///|
declare pub impl[T : @json.FromJson] FromValue for Array[T]

///|
declare pub impl[V : @json.FromJson] FromValue for Map[String, V]

///|
declare pub impl[T : @json.FromJson] FromRow for Array[T]

///|
declare pub impl[V : @json.FromJson] FromRow for Map[String, V]
