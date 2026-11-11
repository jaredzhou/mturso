///|
struct Connection {
  path : String
}

///|
fn connect(path : String) -> Connection {
  { path, }
}

///|
fn Connection::query(self : Connection, sql : String) -> String {
  ignore(self.path)
  let bytes = @utf8.encode(sql)
  let status = host_exec(bytes, bytes.length())
  if status != 0 {
    abort("host exec failed")
  }
  let n = host_result_len()
  let buf = FixedArray::make(n, b'\x00')
  let got = host_result_copy(buf, n)
  if got != n {
    abort("host result copy failed")
  }
  @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes())
}

///|
fn Connection::execute(self : Connection, sql : String) -> Unit {
  ignore(self.query(sql))
}

///|
fn Connection::close(self : Connection) -> Unit {
  ignore(self)
}

///|
fn host_println(msg : String) -> Unit {
  let bytes = @utf8.encode(msg)
  host_log(bytes, bytes.length())
}
