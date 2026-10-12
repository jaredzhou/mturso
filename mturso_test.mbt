///|
async test "basic query" {
  let db = @mturso.Database::open(":memory:")
  let conn = db.connect()
  inspect(
    conn.exec("create table t(id integer primary key, name text)"),
    content="0",
  )
  inspect(
    conn.exec("insert into t(name) values ('alice'), ('bob')"),
    content="2",
  )
  inspect(
    conn.query("select id, name from t order by id"),
    content="1\talice\n2\tbob",
  )
  inspect(conn.query("select 6 * 7"), content="42")
  inspect(conn.query("select count(*) from t"), content="2")
  conn.close()
  db.close()
}

///|
async test "one database, multiple connections" {
  let db = @mturso.Database::open(":memory:")
  let c1 = db.connect()
  let c2 = db.connect()

  ignore(c1.exec("create table t(id integer primary key, v integer)"))
  ignore(c1.exec("insert into t(v) values (1), (2)"))

  // 另一个连接看到的是同一个库
  inspect(c2.query("select count(*) from t"), content="2")
  ignore(c2.exec("insert into t(v) values (3)"))
  inspect(c1.query("select count(*) from t"), content="3")
  inspect(c2.query("select sum(v) from t"), content="6")

  c1.close()
  c2.close()
  db.close()
}

///|
async test "transaction commit and rollback" {
  let db = @mturso.Database::open(":memory:")
  let c1 = db.connect()
  let c2 = db.connect()
  ignore(c1.exec("create table t(id integer primary key, v integer)"))

  ignore(c1.exec("begin"))
  ignore(c1.exec("insert into t(v) values (1)"))
  ignore(c1.exec("commit"))
  inspect(c2.query("select count(*) from t"), content="1")

  ignore(c1.exec("begin"))
  ignore(c1.exec("insert into t(v) values (2)"))
  ignore(c1.exec("rollback"))
  inspect(c2.query("select count(*) from t"), content="1")

  c1.close()
  c2.close()
  db.close()
}

///|
async test "query error raises TursoError" {
  let db = @mturso.Database::open(":memory:")
  let conn = db.connect()
  let mut raised = false
  try conn.query("select * from no_such_table") |> ignore catch {
    @mturso.TursoError(msg) => {
      assert_true(msg.length() > 0)
      raised = true
    }
  } noraise {
    _ => ()
  }
  assert_true(raised)
  conn.close()
  db.close()
}

///|
test "blocking API works without async runtime" {
  let db = @mturso.Database::open(":memory:")
  let conn = db.connect()
  ignore(conn.exec_blocking("create table t(x integer)"))
  ignore(conn.exec_blocking("insert into t values (1), (2)"))
  inspect(conn.query_blocking("select sum(x) from t"), content="3")
  conn.close()
  db.close()
}

///|
async test "慢查询（SQL 里 sleep 2s）不阻塞另一个连接上的快查询" {
  let db = @mturso.Database::open(":memory:")
  let slow = db.connect()
  let fast = db.connect()

  let slow_ms : Ref[Int64] = { val: 0L, }
  let fast_ms : Ref[Int64] = { val: 0L, }

  @async.with_task_group(group => {
    // 慢查询：`turso_sleep(2000)` 在**执行该语句的工作线程**上睡 2 秒
    // 注意：不用 no_wait=true —— 那样任务组退出时不会等它
    group.spawn_bg(() => {
      let t = @async.now()
      inspect(slow.query("select turso_sleep(2000)"), content="2000")
      slow_ms.val = @async.now() - t
    })
    // 等慢查询确实开始了，再在**另一个连接**上发快查询
    @async.sleep(200)
    let t = @async.now()
    inspect(fast.query("select 6 * 7"), content="42")
    fast_ms.val = @async.now() - t
  })

  println(
    "慢查询 select turso_sleep(2000) 返回用时 \{slow_ms.val}ms；快查询 select 6*7 返回用时 \{fast_ms.val}ms",
  )
  // 慢查询确实睡满了 2 秒
  assert_true(slow_ms.val >= 2000L)
  // 快查询在慢查询仍在跑的时候就返回了（若被阻塞，它得等到约 2000ms）
  assert_true(fast_ms.val < 500L)

  slow.close()
  fast.close()
  db.close()
}
