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
  let error = @test.expect_error_async(
    () => conn.query("select * from no_such_table"),
  )
  match error {
    @mturso.TursoError::QueryError(message) =>
      assert_true(message.contains("no such table"))
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }

  ignore(conn.execute("create table unique_t(id integer primary key)"))
  ignore(conn.execute("insert into unique_t values (1)"))
  let error = @test.expect_error_async(
    () => conn.execute("insert into unique_t values (1)"),
  )
  match error {
    @mturso.TursoError::QueryError(message) =>
      assert_true(message.contains("UNIQUE constraint failed"))
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
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
async test "慢 execute 不阻塞另一个连接上的快查询" {
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
      ignore(slow.execute("select turso_sleep(2000)"))
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

  assert_true(slow_ms.val >= 2000L)
  assert_true(fast_ms.val < 1000L)
}

///|
async test "类型化行集：内建类型按类型往返，不再是 TSV 文本" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  let create_sql =
    #|create table typed(
    #|  flag integer, i integer, i64 integer, byte integer, i16 integer,
    #|  u integer, u16 integer, u64 integer, f real, d real,
    #|  s text, c text, b blob, nullable integer, present integer,
    #|  ts text, doc text
    #|)
  ignore(conn.execute(create_sql))
  let document : Json = {"kind":"typed","n":7}
  let insert_sql =
    #|insert into typed values (
    #|  ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
    #|  ?11, ?12, ?13, ?14, ?15, ?16, ?17
    #|)
  ignore(
    conn.execute(
      insert_sql,
      params=[
        true,
        (42 : Int),
        (9_000_000_000L : Int64),
        (200 : Byte),
        (-1234 : Int16),
        (3 : UInt),
        (65_000 : UInt16),
        (5 : UInt64),
        (1.25 : Float),
        2.5,
        "hello",
        'Z',
        b"\x00\xff",
        (None : Int?),
        (Some(7) : Int?),
        @mturso.Timestamp("2026-11-13T12:34:56Z"),
        document,
      ],
    ),
  )
  let select_sql =
    #|select flag, i, i64, byte, i16, u, u16, u64, f, d,
    #|       s, c, b, nullable, present, ts, doc
    #|from typed
  let rows = conn.query(select_sql)
  defer rows.close()
  let cols = rows.columns()
  assert_true(cols.length() == 17)
  assert_true(cols[0].name == "flag")
  assert_true(cols[1].name == "i")
  assert_true(cols[0].decltype.length() > 0)
  assert_true(rows.has_next())
  let row = rows.get_row()
  assert_true(row.len() == 17)
  let flag : Bool = row.get(0)
  assert_true(flag)
  let i : Int = row.get(1)
  assert_true(i == 42)
  let i64 : Int64 = row.get(2)
  assert_true(i64 == 9_000_000_000L)
  let byte : Byte = row.get(3)
  assert_true(byte == (200 : Byte))
  let i16 : Int16 = row.get(4)
  assert_true(i16 == (-1234 : Int16))
  let u : UInt = row.get(5)
  assert_true(u == (3 : UInt))
  let u16 : UInt16 = row.get(6)
  assert_true(u16 == (65_000 : UInt16))
  let u64 : UInt64 = row.get(7)
  assert_true(u64 == (5 : UInt64))
  let f : Float = row.get(8)
  assert_true(f == (1.25 : Float))
  let d : Double = row.get(9)
  assert_true(d == 2.5)
  let s : String = row.get(10)
  assert_true(s == "hello")
  let by_name : String = row.get_by_name("s")
  assert_true(by_name == "hello")
  let c : Char = row.get(11)
  assert_true(c == 'Z')
  let b : Bytes = row.get(12)
  assert_true(b == b"\x00\xff")
  let nullable : Int? = row.get(13)
  assert_true(nullable is None)
  assert_true(row.value(13) == @mturso.Value::Null)
  let present : Int? = row.get_by_name("present")
  assert_true(present == Some(7))
  let ts : @mturso.Timestamp = row.get(15)
  assert_true(ts == @mturso.Timestamp("2026-11-13T12:34:56Z"))
  let doc : Json = row.get(16)
  assert_true(doc.stringify() == document.stringify())
  assert_true(!rows.has_next())

  let projected : Array[(Int, String, Bytes, Int?)] = conn.fetch(
    "select i, s, b, nullable from typed",
  )
  assert_true(projected.length() == 1)
  assert_true(projected[0].0 == 42)
  assert_true(projected[0].1 == "hello")
  assert_true(projected[0].2 == b"\x00\xff")
  assert_true(projected[0].3 is None)

  let error = @test.expect_error(() => {
    let _missing : String = row.get_by_name("missing")
  })
  match error {
    @mturso.TursoError::QueryError(message) =>
      assert_eq(message, "column not found: missing")
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
}

///|
async test "参数化查询：query(sql, params) 走 MoonBit 侧 prepare+bind" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(conn.execute("create table t(a integer, b text)"))
  ignore(conn.execute("insert into t values (1, 'x'), (2, 'y')"))

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
    conn.execute(
      "create table t(a integer, b text, c blob, d integer, e real)",
    ),
  )
  let inserted = conn.execute(
    "insert into t values (?1, ?2, ?3, ?4, ?5)",
    params=[(42 : Int), "hi", b"\x01\x02", (None : Int?), 1.5],
  )
  assert_true(inserted.affected_rows() == 1)

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
  ignore(conn.execute("create table t(id integer, name text)"))
  ignore(conn.execute("insert into t values (1, 'a'), (2, 'b')"))

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

  let error = @test.expect_error_async(() => fetch_one_absent(conn))
  match error {
    @mturso.TursoError::NoRows => ()
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
}

///|
async test "query 遇到多语句明确报错" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  let error = @test.expect_error_async(
    () => conn.query("select 1; select 2"),
  )
  match error {
    @mturso.TursoError::QueryError(message) =>
      assert_eq(
        message,
        "query() accepts a single statement; use execute() for scripts",
      )
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
}

async test "用已关闭的连接 → TursoError::ConnectionError" {
  let db = @mturso.Database::open(":memory:")
  let conn = db.connect()
  conn.close()
  let error = @test.expect_error_async(() => conn.execute("select 1"))
  match error {
    @mturso.TursoError::ConnectionError(message) =>
      assert_eq(message, "connection is closed")
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
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
  let error = @test.expect_error_async(() => tx.commit())
  match error {
    @mturso.TursoError::QueryError(message) =>
      assert_eq(message, "transaction already finished")
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }

  // 已结束事务不能再执行语句
  let error = @test.expect_error_async(() => tx.execute("select 1"))
  match error {
    @mturso.TursoError::QueryError(message) =>
      assert_eq(message, "transaction already finished")
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }

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

  let error = @test.expect_error_async(() => {
    ignore(
      @mturso.begin_func(
        conn,
        async fn(tx) -> Unit raise @mturso.TursoError {
          ignore(tx.execute("insert into t values (2)"))
          ignore(tx.execute("insert into missing values (1)"))
        },
      ),
    )
  })
  match error {
    @mturso.TursoError::QueryError(message) =>
      assert_true(message.contains("no such table"))
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
  assert_true(one_int(conn, "select count(*) from t") == 1L)

  let tx = conn.begin_tx(opts=@mturso.TxOptions::{
    mode: None,
    read_only: Some(true),
  })
  let error = @test.expect_error_async(
    () => tx.execute("insert into t values (3)"),
  )
  match error {
    @mturso.TursoError::QueryError(message) =>
      assert_eq(
        message,
        "Parse error: Cannot execute write statement in query_only mode",
      )
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
  tx.rollback()
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
  let error = @test.expect_error_async(() => {
    let tx2 = c2.begin_tx(opts=@mturso.TxOptions::{
      mode: Some(@mturso.TxMode::Immediate),
      read_only: None,
    })
    tx2.rollback()
  })
  match error {
    @mturso.TursoError::Busy(message) =>
      assert_true(message.contains("database is locked"))
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
  tx1.rollback()
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
  let error = @test.expect_error_async(() => {
    ignore(tx1.execute("update t set v = 1 where id = 1"))
    ignore(tx2.execute("update t set v = 2 where id = 1"))
    tx1.commit()
    tx2.commit()
  })
  match error {
    @mturso.TursoError::Conflict(message) =>
      assert_true(message.contains("Write-write conflict"))
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
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
  let conflict_ready = @cond_var.Cond()
  let release_ready = @cond_var.Cond()
  let mut attempts = 0
  let mut saw_conflict = false
  let mut released = false
  let mut done = false

  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(
        @mturso.retry_tx(
          c2,
          async fn(tx) -> Unit raise @mturso.TursoError {
            attempts = attempts + 1
            if attempts == 1 {
              errdefer {
                saw_conflict = true
                conflict_ready.signal()
              }
              ignore(tx.execute("update t set v = 2 where id = 1"))
            } else {
              try @async.with_timeout(5_000, async fn() {
                while !released {
                  release_ready.wait()
                }
              }) catch {
                error =>
                  abort(
                    "timed out waiting for retry release: \{@debug.to_string(error)}",
                  )
              }
              ignore(tx.execute("update t set v = 2 where id = 1"))
            }
          },
          opts=@mturso.RetryOptions::{
            attempts: 10,
            base_delay_ms: 1,
            max_delay_ms: 10,
            budget_ms: None,
          },
        ),
      )
      done = true
    })
    try @async.with_timeout(5_000, async fn() {
      while !saw_conflict {
        conflict_ready.wait()
      }
    }) catch {
      error =>
        abort(
          "timed out waiting for retry conflict: \{@debug.to_string(error)}",
        )
    }
    tx1.commit()
    released = true
    release_ready.signal()
  })

  assert_true(done)
  assert_true(attempts >= 2)
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
async test "execute 在同一脚本中执行 DDL 和写入" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let result = db.execute("create table t(x integer); insert into t values (1), (2)")
  assert_true(result.affected_rows() == 2)
  let n : Int64 = db.query_one("select count(*) from t").get(0)
  assert_true(n == 2L)
}

///|
async test "UTF-16 String ↔ UTF-8 TEXT：中文/emoji 往返" {
  let db = @mturso.Database::open(":memory:")
  defer db.close()
  let conn = db.connect()
  defer conn.close()
  ignore(conn.execute("create table t(s text)"))
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
  ignore(conn.execute("create table t(s text)"))
  ignore(conn.execute("insert into t values (x'fffe')"))
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
  let error = @test.expect_error_async(() => one.query("select * from missing"))
  match error {
    @mturso.TursoError::QueryError(message) =>
      assert_true(message.contains("no such table"))
    error => fail("unexpected error: \{@debug.to_string(error)}")
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
  assert_true(conn.autocommit())
  ignore(conn.execute("begin"))
  assert_true(!conn.autocommit())
  ignore(conn.execute("commit"))
  assert_true(conn.autocommit())

  conn.close()
  assert_true(conn.is_closed())
  conn.close() // 幂等

  let error = @test.expect_error_async(() => conn.query("select 1"))
  match error {
    @mturso.TursoError::ConnectionError(message) =>
      assert_eq(message, "connection is closed")
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }
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

  let error = @test.expect_error_async(() => conn.query("select 1"))
  match error {
    @mturso.TursoError::ConnectionError(message) =>
      assert_eq(message, "connection is closed")
    error => fail("unexpected error: \{@debug.to_string(error)}")
  }

  let reopened = @mturso.Connection::open(path)
  assert_true(one_int(reopened, "select x from t") == 42L)
  reopened.close()
}
