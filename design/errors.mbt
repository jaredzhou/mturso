// 设计稿：错误模型。

///|
/// 绑定层错误。
///
/// 前三档与 moonpg 的 `PgError` 同构；`Busy` / `Conflict` 是**可重试信号**，
/// 单列出来是为了让 `retry_tx` / `retry_stmt` 能用模式匹配判断（而不是匹配错误文本）：
///
/// - `Busy`：WAL 写锁忙（`TURSO_BUSY`）——**语句级**可重试。
/// - `Conflict`：MVCC 写写冲突（`TURSO_BUSY_SNAPSHOT`）——**事务级**可重试（事务已被中止）。
pub suberror TursoError {
  ConnectionError(String)
  QueryError(String)
  NoRows
  Busy(String)
  Conflict(String)
} derive(Debug)

///|
/// 值转换错误（与数据库错误分开：一个是「取出来的东西不是我想要的类型」，
/// 一个是「数据库那边失败了」）。
pub suberror ValueError {
  ValueError(String)
} derive(Debug)
