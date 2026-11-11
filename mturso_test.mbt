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
  assert_true(fast_ms.val < 500L)
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
  let b : Bytes = row.get(3)
  assert_true(b == b"\x01\x02")
  assert_true(row.value(4) == @mturso.Value::Null)
  assert_true(!rows.has_next())
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
  let _row : (Int, String) = &QueryExecutor::fetch_one(
    conn,
    "select id, name from t where id = 99",
  )
}

///|
async test "fetch / fetch_one：元组建行 + NoRows" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(conn.exec_blocking("create table t(id integer, name text)"))
  ignore(conn.exec_blocking("insert into t values (1, 'a'), (2, 'b')"))

  let all : Array[(Int, String)] = &QueryExecutor::fetch(
    conn,
    "select id, name from t order by id",
  )
  assert_true(all.length() == 2)
  assert_true(all[0].0 == 1)
  assert_true(all[0].1 == "a")
  assert_true(all[1].0 == 2)

  let one : (Int, String) = &QueryExecutor::fetch_one(
    conn,
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

test "用已关闭的连接 → TursoError::ConnectionError" {
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
