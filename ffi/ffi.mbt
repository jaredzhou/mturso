// Turso C ABI 的 raw FFI 层。
//
// 约定（见 notes/turso-binding-guide.md）：
//   - C 侧从不返回 NULL 指针：失败通过 `last_error()` 报告（空串 = 成功）；
//   - 句柄是 GC 托管的外部对象，finalizer 负责释放 Turso 资源；
//   - `Bytes` 由运行时保证 NUL 结尾，可直接当 `const char *` 传给 C。

///|
/// 不透明连接句柄（背后是外部对象）。
pub type Conn

///|
/// 打开数据库。`path` 为 `:memory:` 或文件路径。
#borrow(path)
pub extern "c" fn open(path : Bytes) -> Conn = "mturso_open"

///|
/// 执行 INSERT/UPDATE/DELETE/DDL，返回受影响行数；失败返回 -1。
#borrow(conn, sql)
pub extern "c" fn exec(conn : Conn, sql : Bytes) -> Int64 = "mturso_exec"

///|
/// 执行查询，返回制表符/换行分隔的文本；失败返回空 Bytes。
#borrow(conn, sql)
pub extern "c" fn query(conn : Conn, sql : Bytes) -> Bytes = "mturso_query"

///|
/// 最近一次错误信息（无错误时为空串）。
pub extern "c" fn last_error() -> Bytes = "mturso_last_error"

///|
/// 显式关闭（幂等；不调用也会由 finalizer 释放）。
#borrow(conn)
pub extern "c" fn close(conn : Conn) = "mturso_close"
