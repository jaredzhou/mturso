///|
test "basic query" {
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
test "one database, multiple connections" {
  let db = @mturso.Database::open(":memory:")
  let c1 = db.connect()
  let c2 = db.connect()

  inspect(
    c1.exec("create table t(id integer primary key, v integer)"),
    content="0",
  )
  inspect(c1.exec("insert into t(v) values (1), (2)"), content="2")

  // 另一个连接看到的是同一个库
  inspect(c2.query("select count(*) from t"), content="2")
  // 反过来也能看到
  inspect(c2.exec("insert into t(v) values (3)"), content="1")
  inspect(c1.query("select count(*) from t"), content="3")
  // 查询走各自连接，结果一致
  inspect(c1.query("select sum(v) from t"), content="6")
  inspect(c2.query("select sum(v) from t"), content="6")

  c1.close()
  c2.close()
  db.close()
}

///|
test "transaction commit and rollback" {
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
test "query error raises MtursoError" {
  let db = @mturso.Database::open(":memory:")
  let conn = db.connect()
  let mut raised = false
  try conn.query("select * from no_such_table") |> ignore catch {
    MtursoError::MtursoError(msg) => {
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
