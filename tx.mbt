// 事务：TxMode / TxOptions / Tx / TxBeginner / begin_func。
//
// 本版实现很薄：`begin_tx` 在连接上发 BEGIN，`Tx` 的 query/execute 直接委托给
// 同一条连接（连接本来就是独占、线性的），commit / rollback 发对应 SQL。

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
/// 能开事务的东西（本版：`Connection`）。
pub(open) trait TxBeginner {
  async fn begin_tx(Self, opts? : TxOptions) -> &Tx raise TursoError
}

///|
/// `Connection` 上的事务实现。
pub struct ConnTx {
  conn : Connection
  done : Ref[Bool]
}

///|
pub impl QueryExecutor for ConnTx with query(
  self : ConnTx,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise TursoError {
  self.conn.query(sql, params?)
}

///|
pub impl QueryExecutor for ConnTx with query_one(
  self : ConnTx,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise TursoError {
  self.conn.query_one(sql, params?)
}

///|
pub impl QueryExecutor for ConnTx with execute(
  self : ConnTx,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise TursoError {
  self.conn.execute(sql, params?)
}

///|
pub impl Tx for ConnTx with commit(self) -> Unit raise TursoError {
  if self.done.val {
    raise TursoError::QueryError("transaction already finished")
  }
  self.done.val = true
  ignore(self.conn.execute("commit"))
}

///|
pub impl Tx for ConnTx with rollback(self) -> Unit raise TursoError {
  if self.done.val {
    raise TursoError::QueryError("transaction already finished")
  }
  self.done.val = true
  ignore(self.conn.execute("rollback"))
}

///|
pub extend ConnTx with QueryExecutor::{query, query_one, execute}

///|
pub extend ConnTx with Tx::{commit, rollback}

///|
pub impl TxBeginner for Connection with begin_tx(
  self : Connection,
  opts? : TxOptions,
) -> &Tx raise TursoError {
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
  ConnTx::{ conn: self, done: Ref(false), }
}

///|
pub extend Connection with TxBeginner::{begin_tx}

///|
/// 开事务 → 跑 `f` → 成功 commit；出错 rollback（吞掉 rollback 的错）后重新抛出。
pub async fn[T, B : TxBeginner] begin_func(
  beginner : B,
  f : async (&Tx) -> T raise TursoError,
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
