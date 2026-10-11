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
/// 微秒级 UNIX 时间戳。存成 `Value::Integer`，读回时 `Integer` / `Real` 都能解。
///
/// 「类型即约定」：Turso 没有 timestamp 类型，约定用整数微秒表示。
pub(all) struct Timestamp(Int64) derive(Eq, Debug)

///|
declare pub impl ToValue for Timestamp

///|
declare pub impl FromValue for Timestamp

///|
declare pub impl FromRow for Timestamp
