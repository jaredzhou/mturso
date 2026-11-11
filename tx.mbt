// 事务：TxMode / TxOptions / Tx / TxBeginner / begin_func。
//
// 参考 moonpg：**只有一个具体事务类型 `DbTx`**（将来的池版也复用它，届时会有
// 一个可选的 pool_conn）。`begin_tx` 直接返回 `DbTx` 这个具体类型，所以：
//   - `tx.execute(...)` / `tx.query(...)` / `tx.commit()` 都是普通 dot 调用；
//   - `TxBeginner` 的返回类型对所有实现者一致，`&TxBeginner` 仍然可用。

///|
/// `BEGIN` 的模式。前三个与 SQLite 一一对应；`Concurrent` 是 Turso 的
/// `BEGIN CONCURRENT`（只在 MVCC 下有意义；非 MVCC 下会**硬报错**）。
pub(all) enum TxMode {
  Deferred
  Immediate
  Exclusive
  Concurrent
} derive(Eq, Debug)

///|
/// `begin_tx` 的选项。
pub(all) struct TxOptions {
  mode : TxMode?
  read_only : Bool?
} derive(Eq, Debug)

///|
pub fn TxOptions::default() -> TxOptions {
  { mode: None, read_only: None }
}

///|
/// 进行中的事务：继承 `QueryExecutor`，另有 commit / rollback。
pub(open) trait Tx: QueryExecutor {
  async fn commit(Self) -> Unit raise TursoError
  async fn rollback(Self) -> Unit raise TursoError
}

///|
/// 能开事务的东西（本版：`Connection`；池落地后返回同一个 `DbTx`）。
pub(open) trait TxBeginner {
  async fn begin_tx(Self, opts? : TxOptions) -> DbTx raise TursoError
}

///|
/// 具体事务。`begin_tx` 返回它，所以事务里的调用都是 dot 调用。
pub struct DbTx {
  conn : Connection
  done : Ref[Bool]
}

///|
pub impl QueryExecutor for DbTx with query(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise TursoError {
  self.conn.query(sql, params?)
}

///|
pub impl QueryExecutor for DbTx with query_one(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise TursoError {
  self.conn.query_one(sql, params?)
}

///|
pub impl QueryExecutor for DbTx with execute(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise TursoError {
  self.conn.execute(sql, params?)
}

///|
pub impl Tx for DbTx with commit(self) -> Unit raise TursoError {
  if self.done.val {
    raise TursoError::QueryError("transaction already finished")
  }
  self.done.val = true
  ignore(self.conn.execute("commit"))
}

///|
pub impl Tx for DbTx with rollback(self) -> Unit raise TursoError {
  if self.done.val {
    raise TursoError::QueryError("transaction already finished")
  }
  self.done.val = true
  ignore(self.conn.execute("rollback"))
}

///|
pub extend DbTx with QueryExecutor::{query, query_one, execute}

///|
pub extend DbTx with Tx::{commit, rollback}

///|
pub impl TxBeginner for Connection with begin_tx(
  self : Connection,
  opts? : TxOptions,
) -> DbTx raise TursoError {
  let mode = match opts {
    None => None
    Some(o) => o.mode
  }
  let sql = match mode {
    Some(TxMode::Concurrent) => "begin concurrent"
    Some(TxMode::Immediate) => "begin immediate"
    Some(TxMode::Exclusive) => "begin exclusive"
    _ => "begin"
  }
  ignore(self.execute(sql))
  DbTx::{ conn: self, done: Ref(false), }
}

///|
pub extend Connection with TxBeginner::{begin_tx}

///|
/// 开事务 → 跑 `f` → 成功 commit；出错 rollback（吞掉 rollback 的错）后重新抛出。
pub async fn[T, B : TxBeginner] begin_func(
  beginner : B,
  f : async (DbTx) -> T raise TursoError,
) -> T raise TursoError {
  let tx = beginner.begin_tx()
  errdefer {
    ignore(tx.rollback() catch {
      _ => ()
    })
  }
  let result = f(tx)
  tx.commit()
  result
}
