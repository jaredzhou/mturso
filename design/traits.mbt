// 设计稿：核心 trait 与它们的数据类型。名字与形状照搬 moonpg。

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
/// 按下标取值。类型不符时抛 `TursoError::QueryError`（镜像 moonpg 的做法：
/// `FromValue` 抛的 `ValueError` 在这里被包成数据库错误）。
declare pub fn[T : FromValue] Row::get(
  self : Row,
  index : Int,
) -> T raise TursoError

///|
/// 按列名取值。
declare pub fn[T : FromValue] Row::get_by_name(
  self : Row,
  name : String,
) -> T raise TursoError

///|
/// 该行所属结果集的列描述。
declare pub fn Row::columns(self : Row) -> Array[@value.Column]

///|
/// 取下标的原始 `Value`（不抛——想精确区分类型的人用这个）。
declare pub fn Row::value(self : Row, index : Int) -> @value.Value

///|
/// 取下标的**原始字节**（`Text` 也返回未解码的 UTF-8 字节；不抛）。
declare pub fn Row::value_raw(self : Row, index : Int) -> Bytes

///|
/// 列数。
declare pub fn Row::len(self : Row) -> Int

///|
/// `execute` 的结果。行数通过 `affected_rows()` 拿（对齐 moonpg，不在连接上放 `changes()`）。
declare pub type ExecResult

///|
declare pub fn ExecResult::affected_rows(self : ExecResult) -> Int

///|
declare pub fn ExecResult::close(self : ExecResult) -> Unit

///|
/// 拉取式行读取器（本版是**物化**实现：整个结果集已在内存里；
/// 将来换成流式实现不需要改这个 trait）。
pub(open) trait Rows {
  async fn has_next(Self) -> Bool raise TursoError
  fn get_row(Self) -> Row raise TursoError
  fn columns(Self) -> Array[@value.Column]
  async fn close(Self) -> Unit raise TursoError
}

///|
/// 能执行 SQL 的东西：`Connection`、`Pool`、`PoolConn`、以及 `Tx` 都实现它。
pub(open) trait QueryExecutor {
  /// 只能单语句；多语句请用 `execute`。
  async fn query(Self, String, params? : Array[&ToValue]) -> &Rows raise TursoError
  /// 取一行；零行时抛 `NoRows`。
  async fn query_one(Self, String, params? : Array[&ToValue]) -> Row raise TursoError
  /// 接受多语句（逐条执行），返回累计影响行数。
  async fn execute(Self, String, params? : Array[&ToValue]) -> ExecResult raise TursoError
}

///|
/// 能关闭的东西。
pub(open) trait Closer {
  fn close(Self) -> Unit
}

///|
/// 能从一行构造出来的类型（配合 `fetch` / `fetch_one`）。
pub(open) trait FromRow {
  fn from_row(Row) -> Self raise TursoError
}

///|
/// 收集所有行为 `Array[T]`（自动关闭）。
///
/// 这个不是 `declare` 而是**真函数体**：它只用 trait 上已有的方法
/// （`query` / `has_next` / `get_row` / `close` / `FromRow::from_row`）拼出来，
/// 所以能在这里就验证「用户侧 dot 调用写不写得通」。moonpg 也是这么做的
/// （`declare` 的函数不会注册成可 dot 调用的扩展方法）。
pub async fn[T : FromRow] &QueryExecutor::fetch(
  self : &QueryExecutor,
  sql : String,
  params? : Array[&ToValue],
) -> Array[T] raise TursoError {
  let rows = self.query(sql, params?)
  let result : Array[T] = []
  try {
    while rows.has_next() {
      result.push(T::from_row(rows.get_row()))
    }
    rows.close()
    result
  } catch {
    e => {
      rows.close()
      raise e
    }
  }
}

///|
/// 取恰好一行为 `T`；零行抛 `NoRows`。
pub async fn[T : FromRow] &QueryExecutor::fetch_one(
  self : &QueryExecutor,
  sql : String,
  params? : Array[&ToValue],
) -> T raise TursoError {
  let rows = self.query(sql, params?)
  try {
    if rows.has_next() {
      let row = rows.get_row()
      rows.close()
      return T::from_row(row)
    }
    rows.close()
    raise TursoError::NoRows
  } catch {
    e => {
      rows.close()
      raise e
    }
  }
}
