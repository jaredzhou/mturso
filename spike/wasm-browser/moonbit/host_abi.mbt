// The host is JavaScript. These imports stay deliberately small and synchronous:
// the MoonBit wasm runs in a Worker while the host drives Turso's async wasm API.

///|
#unsafe_skip_stub_check
#borrow(sql)
extern "wasm" fn host_exec(sql : Bytes, len : Int) -> Int = "mturso" "exec"

///|
extern "wasm" fn host_result_len() -> Int = "mturso" "result_len"

///|
#unsafe_skip_stub_check
#borrow(out)
extern "wasm" fn host_result_copy(out : FixedArray[Byte], cap : Int) -> Int = "mturso" "result_copy"

///|
#unsafe_skip_stub_check
#borrow(msg)
extern "wasm" fn host_log(msg : Bytes, len : Int) = "mturso" "log"
