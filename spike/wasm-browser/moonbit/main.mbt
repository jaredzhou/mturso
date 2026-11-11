///|
fn main {
  host_println("=== mturso wasm spike ===")
  let conn = connect(":memory:")
  conn.execute("create table users(id integer primary key, name text)")
  conn.execute("insert into users(name) values ('alice'), ('bob')")

  let users = conn.query("select id, name from users order by id")
  host_println(users)
  if users != "1\talice\n2\tbob" {
    abort("unexpected rows")
  }

  let answer = conn.query("select 6 * 7")
  host_println(answer)
  if answer != "42" {
    abort("expected 42")
  }
  conn.close()
}
