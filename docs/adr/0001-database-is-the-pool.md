# 把连接池并进 Database（Database 即池）

## Status

accepted

## 背景

`design/` 里 v0.2 原计划把「打开库」和「连接池」拆成两个类型：`Database`（连接工厂）
加 `Pool`（线程预算：一条连接 = 一个 C 侧 worker 线程；在池上跑 SQL = 隐式
acquire/release）。代价是关闭顺序只能靠约定 —— 「先 `Pool::close()` / `conn.close()`，
再 `db.close()`」—— 而且 `Database` / `Connection` / `Pool` / `PoolConn` 四个类型里，
后两个基本是前两个的另一层投影。

## 决定

把池的簿记并进 `Database`：`Database` 持有它开出的连接，池相关的方法
（`QueryExecutor` / `TxBeginner` / `Closer` 的 impl）挂在 `Database` 上；`db.close()`
先关掉所有登记连接、再 `turso_database_deinit`。关闭顺序由类型保证，而不是靠约定。

- `Database::open` 改为 `async`（池预热要起 worker 线程）。
- 池配置只保留 `max_conns`；丢掉 `min_idle` / `max_idle_sec`（不做后台维护循环）。
- 两条取连接的路径并存：`db.connect() -> Connection` 是**显式**的（拿一条连接、自己管
  生命周期）；`db.query()` / `db.begin_tx()` 是**隐式**的（池式，内部 acquire/release，
  释放点在你拿到的 `Rows` / `Tx` 用完时）。
- `Connection::close()` 的语义是「我用完这条连接了」—— 把连接**交还给它的 `Database`**，
  句柄随即失效；具体怎么处置由 `Database` 决定：池（来自 `db.connect()`）把它放回 idle、
  worker 线程留着复用（对齐 Go `sql.Conn.Close()`）；私有库（来自 `Connection::open()`）
  因为没有别人能再拿到它，就连着 db 一起拆掉。不单独暴露 `release()`。
- `Connection::open(path)` = 内部一个 `max_conns = 1` 的私有 `Database` 加它那条唯一的连接，
  **不向用户暴露这个 db**。因此不存在「对这种 db 调池式方法、把自己唯一那条连接锁死」
  的自死锁。
- `Connection` 是**唯一**一种连接句柄（即原来 `PoolConn` 的位置）。

## Considered Options

- **保留独立的 `Pool` 类型**（原设计）：类型更分层，但关闭顺序靠约定，
  且 `Pool` / `PoolConn` 与 `Database` / `Connection` 语义重叠。
- **只留连接（conn-centric，像 Python / JDBC）**：少一个类型，但丢掉「文件级生命周期 +
  打开参数（vfs / encryption / experimental）」的合法归属，也丢掉显式的会话句柄。

## Consequences

- C ABI **不会**帮着级联关闭：database 那层只有 `new` / `open` / `connect` / `deinit`，
  所以「关 db 先关所有 conn」全部是绑定层簿记 —— 而这正是池的定义。没有任何一部分连接会被
  引擎自动回收。
- `Closer::close` 的签名是 `fn close(Self) -> Unit`（不抛），级联关闭只能是尽力而为：
  关某条连接失败无法上报。
- `Database` 现在同时是「文件句柄 / 连接工厂 / 池 / 执行入口」；这是有意接受的代价。
- `Database` 登记 `Connection`、`Connection` 又持有 `Database`，会成环。MoonBit 运行时
  有循环回收记账，不会永久泄漏，但 worker 线程加门铃 pipe 的拆除**必须走显式 `close()`**，
  不能指望 GC / finalizer。
- `:memory:` 路径刻意绕过进程级 registry，所以「按路径重复打开会共享」这条对不同
  的 `Connection::open(":memory:")` 不成立 —— 每次都是独立的库。
