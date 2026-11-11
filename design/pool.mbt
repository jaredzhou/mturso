// 设计稿：池的观测数据。
//
// 池已经并入 Database（ADR-0001）：没有独立的 Pool / PoolConn / PoolRows /
// PoolDbTx。`max_conns` 是 `Database::open` 的参数；隐式 acquire/release 由
// `Database` 实现 `QueryExecutor` / `TxBeginner` 提供；池上的事务复用同一个 `DbTx`。

///|
/// 池的观测数据。
#derive(Eq, Debug)
pub(all) struct PoolStats {
  acquire_count : Int64
  acquire_wait_count : Int64
  acquire_wait_duration_ms : Int64
}
