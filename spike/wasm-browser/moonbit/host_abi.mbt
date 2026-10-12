// 宿主契约：和 native 的 C stub（ffi/stub.c）同形，所以 facade 可以长得一模一样。
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
fn host_println(msg : String) -> Unit {
  let b = @utf8.encode(msg)
  host_log(b, b.length())
}
