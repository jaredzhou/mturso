// 设计稿：用法片段。
//
// 这里故意用**普通函数**而不是 `test`：上面所有 API 只有声明、没有实现，
// `moon test` 会真的去调用它们然后炸；普通函数只受 `moon check` 约束，
// 目的就是让编译器验证「这些签名真的能写出调用代码」。

///|
fn usage_open(path : String) -> Database raise TursoError {
  let db = Database::open(path)
  let conn = db.connect()
  println("sqlite_version= \{conn.sqlite_version()}")
  conn.close()
  db.close()
  db
}

///|
async fn usage_query(conn : Connection) -> Unit raise TursoError {
  // 行读取器：拉取式，用完 close（幂等）
  let rows = conn.query("select id, name from users where id > ?1", params=[1])
  let cols : Array[@value.Column] = rows.columns()
  for col in cols {
    println("column: \{col.name} \{col.decltype}")
  }
  while rows.has_next() {
    let row = rows.get_row()
    let id : Int = row.get(0)
    let name : String = row.get_by_name("name")
    println("\{id}: \{name}")
  }
  rows.close()
}

///|
async fn usage_query_one_and_fetch(conn : Connection) -> Unit raise TursoError {
  let one = conn.query_one("select count(*) from users")
  let n : Int64 = one.get(0)
  println("users= \{n}")

  // 收集成结构体数组（自动 close 行读取器）。
  // 注意调用形式：`&Trait` 接收者的扩展方法只能显式 UFCS 调用，不能写
  // `conn.fetch(...)`（moonpg 的测试也是这么写的）。
  let all : Array[(Int, String)] = &QueryExecutor::fetch(
    conn, "select id, name from users",
  )
  let first : (Int, String) = &QueryExecutor::fetch_one(
    conn, "select id, name from users limit 1",
  )
  let (first_id, first_name) = first
  println("\{all.length()} rows, first= \{first_id} \{first_name}")
}

///|
async fn usage_execute(conn : Connection) -> Unit raise TursoError {
  // 多语句：逐条执行，返回影响行数合计
  let r = conn.execute(
    "insert into users(name) values ('alice'); insert into users(name) values ('bob')",
  )
  println("affected= \{r.affected_rows()}")
  r.close()
  println("last rowid= \{conn.last_insert_rowid()}")
}

///|
async fn usage_tx(conn : Connection, pool : Pool) -> Unit raise TursoError {
  // 手动事务：MVCC 下用 BEGIN CONCURRENT 让多个写事务并行
  let tx = conn.begin_tx(opts=TxOptions::{
    mode: Some(TxMode::Concurrent),
    read_only: None,
  })
  ignore(tx.execute("update accounts set balance = balance - 100 where id = 1"))
  ignore(tx.execute("update accounts set balance = balance + 100 where id = 2"))
  tx.commit()

  // 自动提交：冲突（Conflict）时整个事务重跑
  ignore(
    retry_tx(conn, async fn(tx) {
      ignore(
        tx.execute("update accounts set balance = balance + 1 where id = 1"),
      )
      0
    }),
  )

  // 语句级重试：只针对 WAL 写锁忙（Busy）
  ignore(
    retry_stmt(conn, async fn(exec) {
      ignore(exec.execute("insert into logs(msg) values ('hi')"))
      0
    }),
  )

  // 池上也能开事务（TxBeginner），或者用 begin_func 自动 commit/rollback
  ignore(
    begin_func(pool, async fn(tx) {
      ignore(tx.execute("insert into logs(msg) values ('pool')"))
      0
    }),
  )
}

///|
async fn usage_pool(db : Database) -> Unit raise TursoError {
  let pool = Pool::new(db, config=PoolConfig::new(max_conns=4, min_idle=1))

  // 隐式：query/execute 自动 acquire → 用完自动 release
  let rows = pool.query("select 1")
  rows.close()

  // 显式：借出来，自己决定什么时候还
  let pc = pool.acquire()
  ignore(pc.execute("insert into t(x) values (1)"))
  println("total= \{pool.total()} idle= \{pool.idle()}")
  println("acquire= \{pool.stats().acquire_count}")
  pc.release()

  pool.close()
  db.close()
}

///|
async fn usage_errors(conn : Connection) -> Unit raise TursoError {
  ignore(conn.execute("insert into t(id) values (1)")) catch {
    TursoError::Busy(msg) =>
      println("写锁忙（交给 retry_stmt）：\{msg}")
    TursoError::Conflict(msg) =>
      println("MVCC 冲突（重开事务）：\{msg}")
    TursoError::NoRows => println("一行都没有")
    TursoError::QueryError(msg) => println("SQL/约束错：\{msg}")
    TursoError::ConnectionError(msg) =>
      println("连接或生命周期错：\{msg}")
  }
}

///|
fn usage_value_round_trip(row : Row) -> Unit raise TursoError {
  // 值 ↔ 参数：同一套 ToValue/FromValue
  let as_param : Array[&ToValue] = [
    1,
    "alice",
    3.5,
    (None : Int?),
    b"\x01\x02",
  ]
  println("params= \{as_param.length()}")
  // 逐列取值（不抛，自己 match）
  match row.value(0) {
    @value.Value::Null => println("null")
    @value.Value::Integer(i) => println("int \{i}")
    @value.Value::Real(f) => println("real \{f}")
    @value.Value::Text(s) => println("text \{s}")
    @value.Value::Blob(b) => println("blob \{b.length()} bytes")
  }
  // 需要精确字节时走这条（Text 也返回未解码的 UTF-8 字节）
  let raw : Bytes = row.value_raw(0)
  println("raw= \{raw.length()} bytes")
  // 显式类型不符时抛 QueryError（FromValue 的 ValueError 被包了一层）
  let ts : Timestamp = row.get(0)
  match ts {
    Timestamp(us) => println("timestamp= \{us} µs")
  }
}
