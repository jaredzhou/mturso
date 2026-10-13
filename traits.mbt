// 值这一层的 trait 与 `Row`。形状照搬 moonpg（root 包的 tiger 分层）。

///|
/// 能作为 SQL 参数的类型。
pub(open) trait ToValue {
  fn to_value(Self) -> @value.Value
}

///|
/// 能从值里解出来的类型。
pub(open) trait FromValue {
  fn from_value(@value.Value) -> Self raise ValueError
}

///|
/// 一行结果。字段私有，只能通过方法读。
pub struct Row {
  values : Array[@value.Value]
  columns : Array[@value.Column]
}

///|
/// 按下标取值。类型不符时抛 `TursoError`（`FromValue` 抛的 `ValueError` 在这里被
/// 包成数据库错误，镜像 moonpg 的做法）。
pub fn[T : FromValue] Row::get(self : Row, index : Int) -> T raise TursoError {
  let v = self.values[index]
  T::from_value(v) catch {
    ValueError::ValueError(m) => raise TursoError::QueryError("from_value error: \{m}")
  }
}

///|
/// 取下标的原始 `Value`（不抛——想精确区分类型的人用这个）。
pub fn Row::value(self : Row, index : Int) -> @value.Value {
  self.values[index]
}

///|
/// 列数。
pub fn Row::len(self : Row) -> Int {
  self.values.length()
}

///|
/// 该行所属结果集的列描述。
pub fn Row::columns(self : Row) -> Array[@value.Column] {
  self.columns
}

///|
/// 能从一行构造出来的类型（配合 `fetch` / `fetch_one`）。
pub(open) trait FromRow {
  fn from_row(Row) -> Self raise TursoError
}
