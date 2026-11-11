// Database 作为池：隐式 acquire/release + 池统计 + 池上开事务。

///|
/// 池的观测数据。
#derive(Eq, Debug)
pub(all) struct PoolStats {
  acquire_count : Int64
  acquire_wait_count : Int64
  acquire_wait_duration_ms : Int64
}

///|
/// 池统计快照。
pub fn Database::stats(self : Database) -> PoolStats {
  self.stats.val
}

///|
/// 池上限。
pub fn Database::max_conns(self : Database) -> Int {
  self.max_conns
}

// ---------------------------------------------------------------------------
// 隐式 acquire/release：Database 本身实现 QueryExecutor
// ---------------------------------------------------------------------------

///|
pub impl QueryExecutor for Database with query(
  self : Database,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise TursoError {
  let conn = self.connect()
  errdefer conn.close()
  // Rows 读完（或 close）时把连接还回池
  conn.open_rows(sql, params?, release=conn)
}

///|
pub impl QueryExecutor for Database with query_one(
  self : Database,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise TursoError {
  let conn = self.connect()
  defer conn.close()
  conn.query_one(sql, params?)
}

///|
pub impl QueryExecutor for Database with execute(
  self : Database,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise TursoError {
  let conn = self.connect()
  defer conn.close()
  conn.execute(sql, params?)
}

///|
pub extend Database with QueryExecutor::{query, query_one, execute}

// ---------------------------------------------------------------------------
// 池上开事务：仍然复用同一个 DbTx，commit/rollback 时把连接还回池
// ---------------------------------------------------------------------------

///|
pub impl TxBeginner for Database with begin_tx(
  self : Database,
  opts? : TxOptions,
) -> DbTx raise TursoError {
  let conn = self.connect()
  errdefer conn.close()
  conn.begin_tx_internal(opts?, release_pool_conn=true)
}

///|
pub extend Database with TxBeginner::{begin_tx}
