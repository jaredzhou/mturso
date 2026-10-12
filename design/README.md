# `design/` —— mturso 的 API 设计稿（spec）

这个目录是**只有声明、没有实现**的设计稿，用 `declare` 写形状，用
`usage_*.mbt` 里的**普通函数**承载用法片段（不是 `test`：这些 API 还没实现，
写成 test 会在 `moon test` 时真的被调用）。它的作用是让编译器替我们检查
「这套签名真的能写出调用代码」，然后在实现阶段一对一搬进正式包。

校验方式：

```bash
moon check --target native
```

## 落地后的目录映射

| 设计稿 | 实现位置 | 内容 |
| --- | --- | --- |
| `design/value/value.mbt` | `value/` | `Value`、`Column` |
| `design/errors.mbt` | 根包 | `TursoError`、`ValueError` |
| `design/traits.mbt` | 根包 | `Row`/`ExecResult`/`ToValue`/`FromValue`/`Rows`/`QueryExecutor`/`Closer`/`FromRow` |
| `design/values.mbt` | 根包 | 上面这些 trait 的内置类型实例 + `Timestamp` |
| `design/conn.mbt` | 根包 | `Database`、`Connection` |
| `design/tx.mbt` | 根包 | `TxMode`/`TxOptions`/`Tx`/`TxBeginner`/`RetryOptions`/`begin_func`/`retry_tx`/`retry_stmt` |
| `design/pool.mbt` | 根包 | `Pool`/`PoolConn`/`PoolConfig`/`PoolStats`/`PoolRows`/`PoolDbTx` |
| `design/usage.mbt` | 示例 | 用法片段（搬进 `examples/` 与测试） |

根包用 `pub using @value { type Value, type Column }` 转出子包的类型，所以用户
只需要 `@mturso.Value`。

## 照着 moonpg 抄了什么、没抄什么

抄：**用户侧调用手法**（`query`/`query_one`/`execute`/`fetch`/`fetch_one` +
`&QueryExecutor` 扩展方法）、**trait 分层**（`QueryExecutor` ⊃ `Tx`，
`Rows`、`FromRow`、`Closer`、`TxBeginner`）、**目录切分**（根包放 trait 与句柄，
子包放值类型）。

没抄：moonpg 的 OID → codec → wire 那一层。Turso 的 C ABI 直接给出值和类型，
不需要「先把类型码翻译成解码器」这一步，所以 `Row` 里直接是 `Array[Value]`。

差异点（Turso 侧特有）：

1. **一个库多个连接**：`Database::connect()` 可重复调用，每条连接有自己的
   C 侧工作线程；`Database::close()` 在有活连接时会拒绝。
2. **`BEGIN CONCURRENT`**：MVCC 并发写的入口，体现为 `TxMode::Concurrent`。
   冲突是 `TursoError::Conflict`（事务已被中止，必须整事务重开）。
3. **`Busy` vs `Conflict` 分开**：前者是 WAL 写锁忙（语句级重试），后者是 MVCC
   写写冲突（事务级重试）。`retry_stmt` / `retry_tx` 分别只认其中一个。
4. **CDC 与 MVCC 互斥**（同一条连接上二选一），这一版没进 trait 形状。
5. **没有 OID / 没有二进制协议**：`Text` 就是 `String`，非法 UTF-8 宽松解码成
   U+FFFD，需要精确字节走 `Row::value_raw`。

## 写这份 spec 时被编译器打出来的三个坑

都是「不写就不知道」的东西，实现时照抄这里的写法就不会再踩：

1. **`declare pub impl` 不会带出方法。** `declare pub impl Closer for Connection`
   只登记「这个 impl 存在」（能让 trait bound、`&Trait` 强制转换成立），
   但 `conn.close()` 会报 `Type Connection has no method close`。
   所以设计稿里每条具体类型的方法都单独 `declare` 了一遍；实现落地时用
   `pub impl ... with fn ...` 一份就够，不需要重复。
2. **`&Trait` 接收者的扩展方法只能显式 UFCS 调用。** `fetch` / `fetch_one`
   的接收者是 `&QueryExecutor`，所以调用必须写成
   `&QueryExecutor::fetch(conn, sql, params=[...])`；写 `conn.fetch(...)` 会报
   `Type Connection has no method fetch`。moonpg 的测试也正是这么写的。
   （`fetch` / `fetch_one` 在 spec 里是**真函数体**，因为它只用 trait 上已有
   的方法拼出来，顺便验证了这套组合能编译。）
3. **结构体没有「可选字段 / 字段默认值」。** `mode? : TxMode` 这种写法在 struct
   里是语法错误，`mode : TxMode = Deferred` 也不行。所以 `TxOptions` 按 moonpg
   的做法：字段全是 `Option`，另给一个 `TxOptions::default()`。

另外两个小结论：`&T` 里的 `T` 必须是 trait（`&Connection` 编译不过）；
`ExecResult` 之类不能被隐式丢弃，用法里要 `ignore(...)`。

## 实现顺序（已定）

1. `value/` 子包（`Value` / `Column` / `ToValue` / `FromValue`）——纯 MoonBit，不碰 C。
2. C 侧从「TSV 文本」换成**类型化缓冲**，做出 `Rows` / `Row` 的物化版本。
3. traits 落地：把现有 async `query`/`exec` 改造成 `execute -> ExecResult` /
   `query -> &Rows`。
4. `Pool` + `retry_tx` / `retry_stmt`。

每一步都跑 `moon test --target native` 保持现有 6 个测试绿。
