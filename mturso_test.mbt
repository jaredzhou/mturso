///|
async fn one_int(conn : @mturso.Connection, sql : String) -> Int64 {
  let rows = conn.query(sql)
  defer rows.close()
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : Int64 = row.get(0)
  v
}

///|
async fn temp_db(prefix : String) -> (String, String) {
  let dir = @fs.tmpdir(prefix=prefix)
  (dir, dir + "/test.db")
}

///|
async test "basic query" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()

  ignore(conn.execute("create table t(id integer primary key, name text)"))
  let ins = conn.execute("insert into t(name) values ('alice'), ('bob')")
  assert_true(ins.affected_rows() == 2)

  let rows = conn.query("select id, name from t order by id")
  defer rows.close()
  assert_true(rows.has_next())
  let r1 = rows.get_row()
  let id1 : Int = r1.get(0)
  let name1 : String = r1.get(1)
  assert_true(id1 == 1)
  assert_true(name1 == "alice")
  assert_true(rows.has_next())
  let r2 = rows.get_row()
  let id2 : Int = r2.get(0)
  assert_true(id2 == 2)
  assert_true(!rows.has_next())

  assert_true(one_int(conn, "select 6 * 7") == 42L)
  assert_true(one_int(conn, "select count(*) from t") == 2L)
}

///|
async test "one database, multiple connections" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let c1 = db.connect()
  let c2 = db.connect()
  defer c1.close()
  defer c2.close()

  ignore(c1.execute("create table t(id integer primary key, v integer)"))
  ignore(c1.execute("insert into t(v) values (1), (2)"))
  assert_true(one_int(c2, "select count(*) from t") == 2L)
  ignore(c2.execute("insert into t(v) values (3)"))
  assert_true(one_int(c1, "select count(*) from t") == 3L)
  assert_true(one_int(c2, "select sum(v) from t") == 6L)
}

///|
async test "transaction commit and rollback" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let c1 = db.connect()
  let c2 = db.connect()
  defer c1.close()
  defer c2.close()
  ignore(c1.execute("create table t(id integer primary key, v integer)"))

  ignore(c1.execute("begin"))
  ignore(c1.execute("insert into t(v) values (1)"))
  ignore(c1.execute("commit"))
  assert_true(one_int(c2, "select count(*) from t") == 1L)

  ignore(c1.execute("begin"))
  ignore(c1.execute("insert into t(v) values (2)"))
  ignore(c1.execute("rollback"))
  assert_true(one_int(c2, "select count(*) from t") == 1L)
}

///|
async test "query error raises TursoError::QueryError" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  let mut got = false
  try ignore(conn.query("select * from no_such_table")) catch {
    @mturso.TursoError::QueryError(msg) => {
      assert_true(msg.length() > 0)
      got = true
    }
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(got)

  ignore(conn.execute("create table unique_t(id integer primary key)"))
  ignore(conn.execute("insert into unique_t values (1)"))
  let mut constraint = false
  try ignore(conn.execute("insert into unique_t values (1)")) catch {
    @mturso.TursoError::QueryError(msg) => {
      assert_true(msg.length() > 0)
      constraint = true
    }
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(constraint)
}

///|
async test "blocking exec works without async runtime" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(conn.exec_blocking("create table t(x integer)"))
  ignore(conn.exec_blocking("insert into t values (1), (2)"))
  assert_true(one_int(conn, "select sum(x) from t") == 3L)
}

///|
async test "慢查询（SQL 里 sleep 2s）不阻塞另一个连接上的快查询" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let slow = db.connect()
  let fast = db.connect()
  defer slow.close()
  defer fast.close()

  let slow_ms : Ref[Int64] = { val: 0L, }
  let fast_ms : Ref[Int64] = { val: 0L, }

  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let t = @async.now()
      let rows = slow.query("select turso_sleep(2000)")
      assert_true(rows.has_next())
      let v : Int64 = rows.get_row().get(0)
      assert_true(v == 2000L)
      rows.close()
      slow_ms.val = @async.now() - t
    })
    @async.sleep(200)
    let t = @async.now()
    let rows = fast.query("select 6 * 7")
    assert_true(rows.has_next())
    let v : Int64 = rows.get_row().get(0)
    assert_true(v == 42L)
    rows.close()
    fast_ms.val = @async.now() - t
  })

  println(
    "慢查询 select turso_sleep(2000) 返回用时 \{slow_ms.val}ms；快查询 select 6*7 返回用时 \{fast_ms.val}ms",
  )
  assert_true(slow_ms.val >= 2000L)
  assert_true(fast_ms.val < 1000L)
}

///|
async test "类型化行集：整数/浮点/文本/blob/null 按类型取到，不再是 TSV 文本" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(
    conn.exec_blocking(
      "create table t(i integer, r real, s text, b blob, n integer)",
    ),
  )
  ignore(
    conn.exec_blocking(
      "insert into t values (42, 1.5, 'hi', x'0102', null)",
    ),
  )
  let rows = conn.query("select i, r, s, b, n from t")
  defer rows.close()
  let cols = rows.columns()
  assert_true(cols.length() == 5)
  assert_true(cols[0].name == "i")
  assert_true(cols[0].decltype.length() > 0)
  assert_true(rows.has_next())
  let row = rows.get_row()
  let i : Int = row.get(0)
  assert_true(i == 42)
  let r : Double = row.get(1)
  assert_true(r == 1.5)
  let s : String = row.get(2)
  assert_true(s == "hi")
  let by_name : String = row.get_by_name("s")
  assert_true(by_name == "hi")
  let b : Bytes = row.get(3)
  assert_true(b == b"\x01\x02")
  assert_true(row.value(4) == @mturso.Value::Null)
  assert_true(!rows.has_next())

  let mut missing = false
  try {
    let _missing : String = row.get_by_name("missing")
  } catch {
    @mturso.TursoError::QueryError(_) => missing = true
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(missing)
}

///|
async test "参数化查询：query(sql, params) 走 MoonBit 侧 prepare+bind" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(conn.exec_blocking("create table t(a integer, b text)"))
  ignore(conn.exec_blocking("insert into t values (1, 'x'), (2, 'y')"))

  let rows = conn.query("select b from t where a = ?1", params=[2])
  defer rows.close()
  assert_true(rows.has_next())
  let row = rows.get_row()
  let b : String = row.get(0)
  assert_true(b == "y")
  assert_true(!rows.has_next())
}

///|
async test "参数绑定：单个 / 多个 / NULL，结果与字面量一致" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(
    conn.exec_blocking(
      "create table t(a integer, b text, c blob, d integer, e real)",
    ),
  )
  let n = conn.exec_params(
    "insert into t values (?1, ?2, ?3, ?4, ?5)",
    params=[(42 : Int), "hi", b"\x01\x02", (None : Int?), 1.5],
  )
  assert_true(n == 1L)

  let rows = conn.query("select a, b, c, d, e from t")
  defer rows.close()
  assert_true(rows.has_next())
  let row = rows.get_row()
  let a : Int = row.get(0)
  assert_true(a == 42)
  let b : String = row.get(1)
  assert_true(b == "hi")
  let c : Bytes = row.get(2)
  assert_true(c == b"\x01\x02")
  assert_true(row.value(3) == @mturso.Value::Null)
  let e : Double = row.get(4)
  assert_true(e == 1.5)
}

///|
///|
async fn fetch_one_absent(conn : @mturso.Connection) -> Unit raise @mturso.TursoError {
  let _row : (Int, String) = conn.fetch_one("select id, name from t where id = 99")
}

///|
async test "fetch / fetch_one：元组建行 + NoRows" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(conn.exec_blocking("create table t(id integer, name text)"))
  ignore(conn.exec_blocking("insert into t values (1, 'a'), (2, 'b')"))

  let all : Array[(Int, String)] = conn.fetch("select id, name from t order by id")
  assert_true(all.length() == 2)
  assert_true(all[0].0 == 1)
  assert_true(all[0].1 == "a")
  assert_true(all[1].0 == 2)

  let one : (Int, String) = conn.fetch_one(
    "select id, name from t where id = ?1",
    params=[2],
  )
  assert_true(one.0 == 2)
  assert_true(one.1 == "b")

  let mut no_rows = false
  try ignore(fetch_one_absent(conn)) catch {
    @mturso.TursoError::NoRows => no_rows = true
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(no_rows)
}

///|
async test "query 遇到多语句明确报错" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  let mut got = false
  try ignore(conn.query("select 1; select 2")) catch {
    _ => got = true
  } noraise {
    _ => ()
  }
  assert_true(got)
}

async test "用已关闭的连接 → TursoError::ConnectionError" {
  let db = @mturso.Database::open(":memory:")
  let conn = db.connect()
  conn.close()
  let mut got = false
  try ignore(conn.exec_blocking("select 1")) catch {
    @mturso.TursoError::ConnectionError(msg) => {
      assert_true(msg.length() > 0)
      got = true
    }
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(got)
  db.close()
}

///|
///|
async fn insert3(tx : @mturso.DbTx) -> Int raise @mturso.TursoError {
  ignore(tx.execute("insert into t(v) values (3)"))
  0
}

async test "事务：commit / rollback / begin_func / 重复 commit" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let c1 = db.connect()
  let c2 = db.connect()
  defer c1.close()
  defer c2.close()
  ignore(c1.execute("create table t(id integer primary key, v integer)"))

  // commit
  let tx = c1.begin_tx()
  ignore(tx.execute("insert into t(v) values (1)"))
  tx.commit()
  assert_true(one_int(c2, "select count(*) from t") == 1L)

  // 重复 commit 报错
  let mut twice = false
  try ignore(tx.commit()) catch {
    _ => twice = true
  } noraise {
    _ => ()
  }
  assert_true(twice)

  // 已结束事务不能再执行语句
  let mut finished = false
  try ignore(tx.execute("select 1")) catch {
    @mturso.TursoError::QueryError(_) => finished = true
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(finished)

  // rollback（显式 Immediate 模式）
  let tx2 = c1.begin_tx(
    opts=@mturso.TxOptions::{
      mode: Some(@mturso.TxMode::Immediate),
      read_only: None,
    },
  )
  ignore(tx2.execute("insert into t(v) values (2)"))
  tx2.rollback()
  assert_true(one_int(c2, "select count(*) from t") == 1L)

  // begin_func：成功提交
  ignore(@mturso.begin_func(c1, insert3))
  assert_true(one_int(c2, "select count(*) from t") == 2L)
}

///|
async test "事务四种模式与库级默认事务模式" {
  let (dir, path) = temp_db("mturso-tx-modes")
  defer @fs.rmdir(dir, recursive=true)
  let db = @mturso.Database::open(path, max_conns=2)
  defer db.close()
  db.set_journal_mode(@mturso.JournalMode::Mvcc)
  assert_true(db.default_tx_mode() == @mturso.TxMode::Concurrent)

  let conn = db.connect()
  defer conn.close()
  ignore(conn.execute("create table t(x integer)"))

  for mode in [
    @mturso.TxMode::Deferred,
    @mturso.TxMode::Immediate,
    @mturso.TxMode::Exclusive,
    @mturso.TxMode::Concurrent,
  ] {
    let tx = conn.begin_tx(opts=@mturso.TxOptions::{
      mode: Some(mode),
      read_only: None,
    })
    tx.rollback()
  }

  let default_tx = conn.begin_tx()
  default_tx.rollback()

  db.set_default_tx_mode(@mturso.TxMode::Deferred)
  assert_true(db.default_tx_mode() == @mturso.TxMode::Deferred)
}

///|
async test "#5 begin_func 错误回滚、read_only 事务" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(conn.execute("create table t(v integer)"))
  ignore(conn.execute("insert into t values (1)"))

  let mut original = false
  try ignore(
    @mturso.begin_func(
      conn,
      async fn(tx) -> Unit raise @mturso.TursoError {
        ignore(tx.execute("insert into t values (2)"))
        ignore(tx.execute("insert into missing values (1)"))
      },
    ),
  ) catch {
    @mturso.TursoError::QueryError(msg) =>
      original = msg.contains("no such table")
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(original)
  assert_true(one_int(conn, "select count(*) from t") == 1L)

  let tx = conn.begin_tx(opts=@mturso.TxOptions::{
    mode: None,
    read_only: Some(true),
  })
  let mut was_readonly = false
  try ignore(tx.execute("insert into t values (3)")) catch {
    @mturso.TursoError::QueryError(_) => was_readonly = true
    _ => ()
  } noraise {
    _ => ()
  }
  tx.rollback()
  assert_true(was_readonly)
  ignore(conn.execute("insert into t values (4)"))
  assert_true(one_int(conn, "select count(*) from t") == 2L)

  let read_tx = conn.begin_tx(opts=@mturso.TxOptions::{
    mode: None,
    read_only: Some(true),
  })
  assert_true(one_int(conn, "select count(*) from t") == 2L)
  read_tx.commit()
  ignore(conn.execute("insert into t values (5)"))
  assert_true(one_int(conn, "select count(*) from t") == 3L)
}

///|
async test "#3 错误分型：WAL 写锁 -> Busy" {
  let (dir, path) = temp_db("mturso-busy")
  defer @fs.rmdir(dir, recursive=true)
  let db = @mturso.Database::open(path, max_conns=2)
  defer db.close()
  let c1 = db.connect()
  let c2 = db.connect()
  defer c1.close()
  defer c2.close()
  ignore(c1.execute("create table t(x integer)"))

  let tx1 = c1.begin_tx(opts=@mturso.TxOptions::{
    mode: Some(@mturso.TxMode::Immediate),
    read_only: None,
  })
  let mut busy = false
  try {
    let tx2 = c2.begin_tx(opts=@mturso.TxOptions::{
      mode: Some(@mturso.TxMode::Immediate),
      read_only: None,
    })
    tx2.rollback()
  } catch {
    @mturso.TursoError::Busy(_) => busy = true
    _ => ()
  } noraise {
    _ => ()
  }
  tx1.rollback()
  assert_true(busy)
}

///|
async test "#3/#5 MVCC 并发写冲突 -> Conflict" {
  let (dir, path) = temp_db("mturso-conflict")
  defer @fs.rmdir(dir, recursive=true)
  let db = @mturso.Database::open(path, max_conns=2)
  defer db.close()
  db.set_journal_mode(@mturso.JournalMode::Mvcc)
  let c1 = db.connect()
  let c2 = db.connect()
  defer c1.close()
  defer c2.close()
  ignore(c1.execute("create table t(id integer primary key, v integer)"))
  ignore(c1.execute("insert into t values (1, 0)"))

  let tx1 = c1.begin_tx()
  let tx2 = c2.begin_tx()
  let mut conflict = false
  try {
    ignore(tx1.execute("update t set v = 1 where id = 1"))
    ignore(tx2.execute("update t set v = 2 where id = 1"))
    tx1.commit()
    tx2.commit()
  } catch {
    @mturso.TursoError::Conflict(_) => conflict = true
    @mturso.TursoError::QueryError(msg) => abort("unexpected query error: \{msg}")
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(conflict)
}

///|
async test "#6 retry_tx 在真实 MVCC 冲突后重试成功" {
  let (dir, path) = temp_db("mturso-retry")
  defer @fs.rmdir(dir, recursive=true)
  let db = @mturso.Database::open(path, max_conns=2)
  defer db.close()
  db.set_journal_mode(@mturso.JournalMode::Mvcc)
  let c1 = db.connect()
  let c2 = db.connect()
  defer c1.close()
  defer c2.close()
  ignore(c1.execute("create table t(id integer primary key, v integer)"))
  ignore(c1.execute("insert into t values (1, 0)"))

  let tx1 = c1.begin_tx()
  ignore(tx1.execute("update t set v = 1 where id = 1"))
  let attempts : Ref[Int] = { val: 0, }
  let first_attempt : Ref[Bool] = { val: false, }
  let done : Ref[Bool] = { val: false, }

  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(
        @mturso.retry_tx(
          c2,
          async fn(tx) -> Unit raise @mturso.TursoError {
            attempts.val = attempts.val + 1
            first_attempt.val = true
            @async.sleep(10)
            ignore(tx.execute("update t set v = 2 where id = 1"))
          },
          opts=@mturso.RetryOptions::{
            attempts: 10,
            base_delay_ms: 1,
            max_delay_ms: 10,
            budget_ms: None,
          },
        ),
      )
      done.val = true
    })
    while !first_attempt.val {
      @async.sleep(1)
    }
    @async.sleep(40)
    tx1.commit()
  }) catch {
    @mturso.TursoError::QueryError(msg) => abort(msg)
    _ => ()
  } noraise {
    _ => ()
  }

  assert_true(done.val)
  assert_true(attempts.val >= 2)
  assert_true(one_int(c2, "select v from t where id = 1") == 2L)
}

///|
async test "execute 支持多语句：逐条执行、累计影响行数" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  ignore(db.execute("create table t(x integer)"))
  let ev = db.execute("insert into t values (1); insert into t values (2), (3)")
  assert_true(ev.affected_rows() == 3)
  let n : Int64 = db.query_one("select count(*) from t").get(0)
  assert_true(n == 3L)
}

///|
async test "UTF-16 String ↔ UTF-8 TEXT：中文/emoji 往返" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(conn.exec_blocking("create table t(s text)"))
  ignore(conn.execute("insert into t values (?1)", params=["中文🙂"]))

  let rows = conn.query("select s from t")
  defer rows.close()
  assert_true(rows.has_next())
  let row = rows.get_row()
  let s : String = row.get(0)
  // String 是 UTF-16,按字符比较
  assert_true(s == "中文🙂")
  // 线上是 UTF-8:中文 3+3 字节,emoji 4 字节 = 10
  assert_true(row.value_raw(0).length() == 10)
}

///|
async test "value_raw：非法 UTF-8 文本宽松解码 + 原始字节" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(conn.exec_blocking("create table t(s text)"))
  ignore(conn.exec_blocking("insert into t values (x'fffe')"))
  let rows = conn.query("select s from t")
  defer rows.close()
  assert_true(rows.has_next())
  let row = rows.get_row()
  // String <- Blob：宽松解码不报错
  let s : String = row.get(0)
  assert_true(s.length() > 0)
  // 原始字节仍然精确
  assert_true(row.value_raw(0) == b"\xff\xfe")
}

///|
async test "#7 池上隐式 acquire/release + 池事务 + 统计" {
  let db = @mturso.Database::open(":memory:", max_conns=2)
  defer db.close()
  // 隐式：db.execute / db.query，用完自动归还
  ignore(db.execute("create table t(x integer)"))
  ignore(db.execute("insert into t values (1)"))
  let rows = db.query("select x from t")
  assert_true(rows.has_next())
  let v : Int = rows.get_row().get(0)
  assert_true(v == 1)
  rows.close()

  // 池事务：commit 后连接自动还回池
  let tx = db.begin_tx()
  ignore(tx.execute("insert into t values (2)"))
  tx.commit()
  let n : Int64 = db.query_one("select count(*) from t").get(0)
  assert_true(n == 2L)

  let st = db.stats()
  assert_true(st.acquire_count >= 5L)

  // 查询失败也不能泄漏池里的唯一许可
  let one = @mturso.Database::open(":memory:", max_conns=1)
  defer one.close()
  ignore(one.execute("create table t(x integer)"))
  try ignore(one.query("select * from missing")) catch {
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(one.query_one("select 1").get(0) == 1)
}

///|
async test "#7 池：复用连接、max_conns 等待、db.close 级联" {
  let db = @mturso.Database::open(":memory:", max_conns=2)
  let c1 = db.connect()
  let c2 = db.connect()
  ignore(c1.execute("create table t(x integer)"))
  ignore(c2.execute("insert into t values (1)"))
  c1.close()
  c2.close()
  assert_true(c1.is_closed())

  // 复用 idle 里的连接
  let c3 = db.connect()
  assert_true(one_int(c3, "select count(*) from t") == 1L)
  c3.close()

  // max_conns=2：借满两条后，第三条要等别人归还
  let a = db.connect()
  let b = db.connect()
  let got : Ref[Bool] = { val: false, }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let third = db.connect()
      got.val = true
      third.close()
    })
    @async.sleep(50)
    assert_true(!got.val)
    a.close()
  })
  assert_true(got.val)
  b.close()
  let st = db.stats()
  assert_true(st.acquire_wait_count >= 1L)
  assert_true(st.acquire_wait_duration_ms >= 0L)

  db.close()
  assert_true(db.is_closed())
}

///|
async test "观测方法：is_closed / last_insert_rowid / sqlite_version" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  assert_true(!conn.is_closed())
  ignore(conn.execute("create table t(id integer primary key, v integer)"))
  ignore(conn.execute("insert into t(v) values (7)"))
  assert_true(conn.last_insert_rowid() == 1L)
  assert_true(conn.sqlite_version() == "3.50.4")

  conn.close()
  assert_true(conn.is_closed())
  conn.close() // 幂等

  let mut got = false
  try ignore(conn.query("select 1")) catch {
    @mturso.TursoError::ConnectionError(_) => got = true
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(got)
}

///|
async test "#7 Connection::open 持有私有 max_conns=1 Database" {
  let (dir, path) = temp_db("mturso-connection-open")
  defer @fs.rmdir(dir, recursive=true)
  let conn = @mturso.Connection::open(path)
  ignore(conn.execute("create table t(x integer)"))
  ignore(conn.execute("insert into t values (42)"))
  assert_true(one_int(conn, "select x from t") == 42L)
  conn.close()
  assert_true(conn.is_closed())
  conn.close()

  let mut closed = false
  try ignore(conn.query("select 1")) catch {
    @mturso.TursoError::ConnectionError(_) => closed = true
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(closed)

  let reopened = @mturso.Connection::open(path)
  assert_true(one_int(reopened, "select x from t") == 42L)
  reopened.close()
}
