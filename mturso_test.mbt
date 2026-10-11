///|
test "basic query" {
  let conn = @mturso.Conn::open(":memory:")
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
}

///|
test "query error raises MtursoError" {
  let conn = @mturso.Conn::open(":memory:")
  let mut raised = false
  try conn.query("select * from no_such_table") |> ignore catch {
    MtursoError::MtursoError(msg) => {
      // 错误信息由 Turso 提供，至少包含表名
      assert_true(msg.length() > 0)
      raised = true
    }
  } noraise {
    _ => ()
  }
  assert_true(raised)
  conn.close()
}
