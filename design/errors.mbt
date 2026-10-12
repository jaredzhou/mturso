// 设计稿：错误模型。

///|
/// 绑定层错误。
///
/// 前三档与 moonpg 的 `PgError` 同构；`Busy` / `Conflict` 是**可重试信号**，
/// 单列出来是为了让重试助手能用模式匹配判断（而不是匹配错误文本）：
///
/// - `Busy`：写锁忙（`TURSO_BUSY`）。
/// - `Conflict`：MVCC 写写冲突（`TURSO_BUSY_SNAPSHOT`），事务已被中止。
///
/// 撞到哪一个**不取决于**你用哪个重试助手，而取决于这条连接的运行模式：
/// 没开 MVCC（或开了 MVCC 但用普通 `BEGIN`）走写者互斥 → `Busy`；
/// MVCC + `BEGIN CONCURRENT` 走乐观并发 → 提交时 `Conflict`。
/// 两者都是「可重试」，`retry_tx` 重试的就是这一档错误；没有语句级助手 ——
/// 读不需要重试，写要能重试就显式走事务，见 `tx.mbt`。
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
