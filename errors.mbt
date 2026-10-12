// 错误模型。
//
// `TursoError` 的前三档与 moonpg 的 `PgError` 同构；`Busy` / `Conflict` 是可重试信号。
// 本阶段（ticket #2）仍是单变体，ticket #3 会拆成
// ConnectionError / QueryError / NoRows / Busy / Conflict。

///|
/// 绑定层错误。
pub suberror TursoError {
  TursoError(String)
}

///|
/// 值转换错误（与数据库错误分开：一个是「取出来的东西不是我想要的类型」，
/// 一个是「数据库那边失败了」）。
pub(all) suberror ValueError {
  ValueError(String)
}
