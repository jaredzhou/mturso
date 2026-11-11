// 白盒：闭包内主动抛 Conflict / Busy —— 外部包不能构造 TursoError 变体。

///|
async test "retry_tx：只重试 Conflict/Busy，不可重试立即冒泡" {
  let db = Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(conn.execute("create table t(x integer)"))

  let attempts : Ref[Int] = { val: 0, }
  let r = retry_tx(
    conn,
    async fn(_tx) -> Int raise TursoError {
      @async.sleep(0)
      attempts.val = attempts.val + 1
      if attempts.val < 3 {
        raise TursoError::Conflict("boom")
      }
      42
    },
    opts={ attempts: 5, base_delay_ms: 1, max_delay_ms: 4, budget_ms: None },
  )
  assert_true(r == 42)
  assert_true(attempts.val == 3)

  // Busy 也是可重试的
  let attempts_busy : Ref[Int] = { val: 0, }
  let r2 = retry_tx(
    conn,
    async fn(_tx) -> Int raise TursoError {
      @async.sleep(0)
      attempts_busy.val = attempts_busy.val + 1
      if attempts_busy.val < 2 {
        raise TursoError::Busy("busy")
      }
      7
    },
    opts={ attempts: 3, base_delay_ms: 1, max_delay_ms: 4, budget_ms: None },
  )
  assert_true(r2 == 7)
  assert_true(attempts_busy.val == 2)

  // 不可重试的错误立即冒泡，且只执行一次
  let attempts3 : Ref[Int] = { val: 0, }
  let mut got = false
  try ignore(
    retry_tx(
      conn,
      async fn(_tx) -> Int raise TursoError {
        @async.sleep(0)
        attempts3.val = attempts3.val + 1
        raise TursoError::QueryError("no")
      },
    ),
  ) catch {
    TursoError::QueryError(_) => got = true
    _ => ()
  } noraise {
    _ => ()
  }
  assert_true(got)
  assert_true(attempts3.val == 1)
}
