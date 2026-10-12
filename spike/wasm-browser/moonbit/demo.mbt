// spike：MoonBit(wasm1) 通过宿主导入函数驱动 Turso。
// 宿主契约（和我们 native 的 C stub 同形，便于复用 facade）：
//   exec(sql_ptr, sql_len) -> 0 成功 / 负数失败
//   result_len() -> 结果字节数
//   result_copy(out_ptr, cap) -> 实际拷贝的字节数
//   log(msg_ptr, msg_len)

///|
#unsafe_skip_stub_check
#borrow(sql)
extern "wasm" fn host_exec(sql : Bytes, len : Int) -> Int = "mturso" "exec"

///|
#unsafe_skip_stub_check
extern "wasm" fn host_result_len() -> Int = "mturso" "result_len"

///|
#unsafe_skip_stub_check
#borrow(out)
extern "wasm" fn host_result_copy(out : FixedArray[Byte], cap : Int) -> Int =
  "mturso" "result_copy"

///|
#unsafe_skip_stub_check
#borrow(msg)
extern "wasm" fn host_log(msg : Bytes, len : Int) -> Unit = "mturso" "log"

///|
fn log(msg : String) -> Unit {
  let b = @utf8.encode(msg)
  host_log(b, b.length())
}

///|
fn run(sql : String) -> Unit {
  let b = @utf8.encode(sql)
  if host_exec(b, b.length()) < 0 {
    log("EXEC FAILED: " + sql)
    return
  }
  let n = host_result_len()
  if n <= 0 {
    return
  }
  let buf : FixedArray[Byte] = FixedArray::make(n + 1, b'\x00')
  let got = host_result_copy(buf, n + 1)
  if got > 0 {
    log(@utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:got]))
  }
}

///|
pub fn mt_demo() -> Int {
  log("=== MoonBit (wasm) -> Turso ===")
  run("create table users(id integer primary key, name text, city text)")
  run("insert into users(name, city) values ('alice','revkjavik'), ('bob','shanghai')")
  run("select id, name, city from users order by id")
  run("select count(*) from users")
  run("select 6 * 7")
  0
}
