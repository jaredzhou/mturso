// Turso 存储层的值类型。

///|
/// Turso 存储层只有五种值（对应 C ABI 的 `TURSO_TYPE_*`）。
///
/// - `Text` 用 `String`：类型本身承载「这是文本」的语义。
///   非法 UTF-8 的字节在构造时**宽松解码**（替换为 U+FFFD），不报错；
///   需要精确字节请走 `Row::value_raw`。
/// - `Blob` 用 `Bytes`：与 `Text` 靠变体区分，不做「看起来像文本就当文本」的自动提升。
pub(all) enum Value {
  Null
  Integer(Int64)
  Real(Double)
  Text(String)
  Blob(Bytes)
} derive(Eq, Debug)

///|
/// 列的元信息。`decltype` 来自 C ABI 的 `column_decltype`，**可能是空串**（SQLite 常见）。
pub(all) struct Column {
  name : String
  decltype : String
} derive(Eq, Debug)
