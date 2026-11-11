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
  raw : Array[Bytes]
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
/// 取下标的**原始字节**（`Text` 返回未解码的 UTF-8 字节，`Blob` 返回其字节；
/// 其它类型返回空）。
pub fn Row::value_raw(self : Row, index : Int) -> Bytes {
  self.raw[index]
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

///|
/// 能执行 SQL 的东西。
pub(open) trait QueryExecutor {
  /// 只能单语句；多语句请用 `execute`。
  async fn query(Self, String, params? : Array[&ToValue]) -> &Rows raise TursoError
  /// 取一行；零行时抛 `NoRows`。
  async fn query_one(Self, String, params? : Array[&ToValue]) -> Row raise TursoError
  /// 执行（本版单语句），返回受影响行数。
  async fn execute(Self, String, params? : Array[&ToValue]) -> ExecResult raise TursoError
}

///|
/// 能关闭的东西。
pub(open) trait Closer {
  fn close(Self) -> Unit
}

///|
/// `execute` 的结果。
pub struct ExecResult {
  changes : Int64
}

///|
/// 受影响行数。
pub fn ExecResult::affected_rows(self : ExecResult) -> Int {
  self.changes.to_int()
}

///|
/// 收集所有行为 `Array[T]`（自动关闭）。
pub async fn[T : FromRow] &QueryExecutor::fetch(
  self : &QueryExecutor,
  sql : String,
  params? : Array[&ToValue],
) -> Array[T] raise TursoError {
  let rows = self.query(sql, params?)
  errdefer rows.close()
  let result : Array[T] = []
  while rows.has_next() {
    result.push(T::from_row(rows.get_row()))
  }
  rows.close()
  result
}

///|
/// 取恰好一行为 `T`；零行抛 `NoRows`。
pub async fn[T : FromRow] &QueryExecutor::fetch_one(
  self : &QueryExecutor,
  sql : String,
  params? : Array[&ToValue],
) -> T raise TursoError {
  let rows = self.query(sql, params?)
  errdefer rows.close()
  if rows.has_next() {
    let row = rows.get_row()
    rows.close()
    return T::from_row(row)
  }
  rows.close()
  raise TursoError::NoRows
}

///|
/// 能按 `FromRow` 把 SELECT 结果收成 `T` 的类型。
///
/// `fetch` / `fetch_one` 对 `T` 泛型，不能放进 `QueryExecutor`（那会让 trait
/// 不能当对象用，而 `&QueryExecutor` / `&Tx` 是 API 的一部分）。所以它们住在
/// 这个单独的非 object-safe trait 里，共享一份默认实现。
pub(open) trait Fetching: QueryExecutor {
  async fn[T : FromRow] fetch(Self, String, params? : Array[&ToValue]) -> Array[
    T,
  ] raise TursoError = _
  async fn[T : FromRow] fetch_one(Self, String, params? : Array[&ToValue]) -> T raise TursoError = _
}

///|
/// `Fetching` 的共享默认实现：转发到 `&QueryExecutor::fetch` / `fetch_one`。
impl Fetching with fn[T : FromRow] fetch(
  self,
  sql : String,
  params? : Array[&ToValue],
) -> Array[T] {
  &QueryExecutor::fetch(self, sql, params?)
}

///|
impl Fetching with fn[T : FromRow] fetch_one(
  self,
  sql : String,
  params? : Array[&ToValue],
) -> T {
  &QueryExecutor::fetch_one(self, sql, params?)
}
