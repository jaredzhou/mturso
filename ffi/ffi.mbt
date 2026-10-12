// Turso C ABI 的 raw FFI 层。
//
// 约定（见 notes/turso-binding-guide.md）：
//   - C 侧从不返回 NULL 指针：失败通过 `last_error()` 报告（空串 = 成功）；
//   - `Db` / `Conn` 都是 GC 托管的外部对象，finalizer 负责释放原生资源；
//   - MoonBit 的 `Bytes` 由运行时保证 NUL 结尾，可直接当 `const char *` 传给 C；
//   - 一个 `Db` 可以 connect 出**多个** `Conn`（`turso_database_connect` 可重复调用）。

///|
/// 不透明的数据库句柄（背后是外部对象）。
pub type Db

///|
/// 不透明的连接句柄（背后是外部对象）。
pub type Conn

///|
/// 打开数据库。`path` 为 `:memory:` 或文件路径。
#borrow(path)
pub extern "c" fn db_open(path : Bytes) -> Db = "mturso_db_open"

///|
/// 从数据库开一个连接。**可重复调用**，每个连接有独立的事务/语句状态。
#borrow(db)
pub extern "c" fn db_connect(db : Db) -> Conn = "mturso_db_connect"

///|
/// 显式关闭数据库（幂等；不调用也会由 finalizer 释放）。
#borrow(db)
pub extern "c" fn db_close(db : Db) = "mturso_db_close"

///|
/// 执行 INSERT/UPDATE/DELETE/DDL，返回受影响行数；失败返回 -1。
#borrow(conn, sql)
pub extern "c" fn conn_exec(conn : Conn, sql : Bytes) -> Int64 = "mturso_conn_exec"

///|
/// 执行查询，返回制表符/换行分隔的文本；失败返回空 `Bytes`。
#borrow(conn, sql)
pub extern "c" fn conn_query(conn : Conn, sql : Bytes) -> Bytes = "mturso_conn_query"

///|
/// 显式关闭连接（幂等）。
#borrow(conn)
pub extern "c" fn conn_close(conn : Conn) = "mturso_conn_close"

///|
/// 最近一次错误信息（无错误时为空串）。
pub extern "c" fn last_error() -> Bytes = "mturso_last_error"

// ---------------------------------------------------------------------------
// 异步路径：提交给本连接的工作线程，完成后敲「门铃」pipe
// ---------------------------------------------------------------------------

///|
/// 立刻返回：把查询提交给本连接的工作线程执行。
#borrow(conn, sql)
pub extern "c" fn submit_query(conn : Conn, sql : Bytes) = "mturso_submit_query"

///|
/// 立刻返回：把非查询语句提交给本连接的工作线程执行。
#borrow(conn, sql)
pub extern "c" fn submit_exec(conn : Conn, sql : Bytes) = "mturso_submit_exec"

///|
/// 取回门铃的读端 fd（**所有权转移**给调用方，只能取一次）。失败返回 -1。
#borrow(conn)
pub extern "c" fn conn_bell_fd(conn : Conn) -> Int32 = "mturso_conn_bell_fd"

///|
/// 取回异步查询结果（失败返回空 `Bytes`，原因见 `last_error()`）。
#borrow(conn)
pub extern "c" fn take_query(conn : Conn) -> Bytes = "mturso_take_query"

///|
/// 取回异步 exec 的受影响行数（失败返回 -1）。
#borrow(conn)
pub extern "c" fn take_exec(conn : Conn) -> Int64 = "mturso_take_exec"
