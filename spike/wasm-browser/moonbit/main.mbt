// 用户程序：只用上面那层 mini facade，最后整包编成 wasm。

///|
fn main {
  host_println("=== 一个用了 mturso(wasm) 的 MoonBit 程序 ===")

  let conn = connect(":memory:")
  conn.execute("create table users(id integer primary key, name text, city text)")
  conn.execute(
    "insert into users(name, city) values ('alice','revkjavik'), ('bob','shanghai')",
  )

  host_println(conn.query("select id, name, city from users order by id"))
  host_println("count = " + conn.query("select count(*) from users"))
  host_println("6 * 7 = " + conn.query("select 6 * 7"))

  conn.close()
}
