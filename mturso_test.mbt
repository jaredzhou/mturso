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
async test "query error raises MtursoError" {
  let db = @mturso.Database::open(":memory:")
  let conn = db.connect()
  let mut raised = false
  try conn.query("select * from no_such_table") |> ignore catch {
    @mturso.MtursoError(msg) => {
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
async test "concurrent queries do not block the event loop" {
  let db = @mturso.Database::open(":memory:")
  let c1 = db.connect()
  let c2 = db.connect()

  // 一个足够重的查询，保证 worker 要跑几十毫秒
  let heavy =
    #|with recursive c(i) as (select 1 union all select i + 1 from c where i < 300000)
    #|select count(*) from c

  let q_started : Ref[Bool] = { val: false, }
  let q_done : Ref[Bool] = { val: false, }
  let slept_during_query : Ref[Bool] = { val: false, }

  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      @async.sleep(20)
      // 如果查询还在跑，说明事件循环在这 20ms 里照常调度的别的任务
      slept_during_query.val = q_started.val && !q_done.val
    })
    q_started.val = true
    inspect(c1.query(heavy), content="300000")
    q_done.val = true
    // 另一个连接完全不受影响
    inspect(c2.query("select 6 * 7"), content="42")
  })

  assert_true(slept_during_query.val)
  c1.close()
  c2.close()
  db.close()
}
