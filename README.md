# mturso

MoonBit 的 [Turso](https://turso.tech) 客户端 —— 基于官方 C ABI（`turso.h`），native 目标，SQL 方言与 SQLite 兼容。

![target](https://img.shields.io/badge/target-native-blue)
![turso](https://img.shields.io/badge/turso-0.8.2-informational)
![license](https://img.shields.io/badge/license-Apache--2.0-green)

Turso 是 SQLite 的 Rust 重写版。`mturso` 把它接进 MoonBit：`Database` 是连接工厂，`Connection` 承载 SQL。
每条连接自带一个 **C 侧工作线程**，查询是 **async** 的 —— 语句在线程里执行，MoonBit 的事件循环不会被卡住。

```moonbit
let db = @mturso.Database::open(":memory:")
let conn = db.connect()
ignore(conn.exec("create table t(id integer primary key, name text)"))
ignore(conn.exec("insert into t(name) values ('alice'), ('bob')"))
println(conn.query("select id, name from t order by id"))   // 1\talice\n2\tbob
conn.close()
db.close()
```

## 特性

- **一个库，多个连接** —— `db.connect()` 想开几个开几个，各连接有自己的语句/事务状态、独立的工作线程；
- **查询不阻塞事件循环** —— 阻塞只发生在连接自己的工作线程里，完成后通过「门铃」pipe 唤醒 await 的那一侧；
- **SQLite 兼容** —— `select sqlite_version()` 报 `3.50.4`；DDL/DML、`begin`/`commit`/`rollback` 等直接可用；
- **同步 API 备用** —— `query_blocking` / `exec_blocking` 在调用线程上直接跑，不需要 async 运行时；
- **自带引擎** —— Turso 动态库随仓库提供（`libs/`，约 20MB），不需要另外装引擎。

## 安装

还没发布到 mooncakes，用 **workspace** 从源码接入（下面这套流程已实测跑通）：

```bash
git clone git@github.com:jaredzhou/mturso.git
cd your-project
moon work init /path/to/mturso .        # 把 mturso 和你的模块放进同一个 workspace
```

你的 `moon.mod`：

```toml
import {
  "moonbitlang/async@0.22.4",
  "jaredzhou/mturso@0.1.0",
}
```

你的**根包** `moon.pkg` —— 除了 import，还要把 Turso 的动态库链接进最终产物：

```moonbit
import {
  "jaredzhou/mturso",
  "moonbitlang/async",
}

options(
  link: {
    "native": {
      "cc-link-flags": "-L/path/to/mturso/libs -lturso_sync_sdk_kit -Wl,-rpath,/path/to/mturso/libs",
    },
  },
)
```

> 为什么要自己写这段：MoonBit 目前不会把依赖包 `moon.pkg` 里的 `cc-link-flags` 传递给下游的最终链接，
> 而链接发生在**你的根包**。仓库自己的 `moon.pkg` / `ffi/moon.pkg` 已经写好同样的参数，所以 `moon test` 直接可用；
> 接入方需要复制一份（把 `/path/to/mturso` 换成实际路径）。

## 快速上手

async 版本（推荐：查询不会阻塞事件循环）：

```moonbit
async fn main {
  let db = @mturso.Database::open(":memory:")     // 也可以给文件路径 "./demo.db"
  let conn = db.connect()

  ignore(conn.exec("create table t(id integer primary key, name text)"))
  ignore(conn.exec("insert into t(name) values ('alice'), ('bob')"))

  println(conn.query("select id, name from t order by id"))
  // 1	alice
  // 2	bob

  conn.close()
  db.close()
}
```

不想要 async 运行时，就用同步版本：

```moonbit
fn main raise @mturso.TursoError {
  let db = @mturso.Database::open(":memory:")
  let conn = db.connect()
  ignore(conn.exec_blocking("create table t(x integer)"))
  ignore(conn.exec_blocking("insert into t values (1), (2)"))
  println(conn.query_blocking("select sum(x) from t"))   // 3
  conn.close()
  db.close()
}
```

## 示例

### 一个库，多个连接

同一个库上的多个连接互相看得到对方的提交：

```moonbit
async fn demo() -> Unit raise @mturso.TursoError {
  let db = @mturso.Database::open(":memory:")
  let c1 = db.connect()
  let c2 = db.connect()

  ignore(c1.exec("create table t(id integer primary key, v integer)"))
  ignore(c1.exec("insert into t(v) values (1), (2)"))

  println(c2.query("select count(*) from t"))   // 2 —— 另一个连接看到的是同一个库
  ignore(c2.exec("insert into t(v) values (3)"))
  println(c1.query("select count(*) from t"))   // 3

  c1.close()
  c2.close()
  db.close()
}
```

### 并发：慢查询不阻塞别的连接

每条连接一个工作线程，所以在一条连接上跑 2 秒的查询时，另一条连接上的查询照样立刻返回：

```moonbit
async fn demo() -> Unit raise @mturso.TursoError {
  let db = @mturso.Database::open(":memory:")
  let slow = db.connect()
  let fast = db.connect()
  let fast_ms : Ref[Int64] = { val: 0L, }

  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(slow.query("select turso_sleep(2000)"))   // 在慢连接自己的线程上睡 2 秒
    })
    @async.sleep(100)                                  // 等慢查询真的开始
    let t = @async.now()
    ignore(fast.query("select 6 * 7"))
    fast_ms.val = @async.now() - t
  })

  println("快查询用时 \{fast_ms.val}ms（慢查询还在跑）")   // 实测 1ms
  slow.close()
  fast.close()
  db.close()
}
```

`turso_sleep(ms)` 是绑定在每个连接上注册的诊断用标量函数（不是引擎内置）：它在**执行该语句的线程**上睡眠，
所以能直接在 SQL 里制造慢查询。

### 事务

事务就是挂在某一条连接上的普通 SQL；回滚后别的连接看不到中间状态：

```moonbit
async fn demo() -> Unit raise @mturso.TursoError {
  let db = @mturso.Database::open(":memory:")
  let c1 = db.connect()
  let c2 = db.connect()
  ignore(c1.exec("create table t(id integer primary key, v integer)"))

  ignore(c1.exec("begin"))
  ignore(c1.exec("insert into t(v) values (1)"))
  ignore(c1.exec("commit"))
  println(c2.query("select count(*) from t"))   // 1

  ignore(c1.exec("begin"))
  ignore(c1.exec("insert into t(v) values (2)"))
  ignore(c1.exec("rollback"))
  println(c2.query("select count(*) from t"))   // 1

  c1.close()
  c2.close()
  db.close()
}
```

### 错误处理

数据库错误统一是 `@mturso.TursoError`，`catch` 出来带引擎的原始消息：

```moonbit
async fn demo(conn : @mturso.Connection) -> Unit raise @mturso.TursoError {
  try {
    ignore(conn.query("select * from no_such_table"))
  } catch {
    @mturso.TursoError(msg) => println("Turso 报错：\{msg}")
  }
}
```

## API 概览

| API | 说明 |
| --- | --- |
| `Database::open(path)` | 打开文件库或 `":memory:"` |
| `Database::connect()` | 开一条连接（每连接一个 C 侧工作线程） |
| `Database::close()` | 关闭数据库（幂等） |
| `Connection::query(sql)` | **async**；跑单条查询，返回制表符分隔的文本 |
| `Connection::exec(sql)` | **async**；跑 DDL/DML，返回受影响行数（`Int64`） |
| `Connection::query_blocking(sql)` / `exec_blocking(sql)` | 同步版本，不需要 async 运行时 |
| `Connection::close()` | 关闭连接、回收工作线程（幂等） |
| `TursoError` | 唯一的错误类型，`catch` 出来带引擎消息 |

## 已知限制

- **还没有参数绑定** —— 值只能字面量写进 SQL，下一版会加 `params?` 位置参数；
- **结果还是文本** —— `query` 返回制表符分隔的字符串，`NULL` 显示为 `NULL`、`BLOB` 显示为 `<blob>`，没有类型化取值；
- **没有取消/超时** —— 语句一旦提交就会跑完（Turso 的 C ABI 没有跨线程取消）；
- **只有 native 目标** —— 依赖 C 动态库，暂不支持 wasm/js；
- **preview 引擎** —— Turso 0.8.2 是预览版，不少特性藏在实验开关后面，别当成生产级 SQLite。

## 路线图

类型化值（`Value`/`Column`）、参数绑定、物化行集（`Rows`/`Row`）、事务对象（`Tx`/`begin_tx`，含
`BEGIN CONCURRENT`）、重试助手（`retry_tx` / `retry_stmt`）、连接池（`Pool`）都已经写成一份可被编译器
校验的**设计稿**（`design/`，`moon check` 0 warning），会按 ① 值子包 → ② C 侧类型化缓冲 →
③ traits 落地 → ④ 池 + 重试 的顺序实现，接口形状对齐
[`jaredzhou/moonpg`](https://github.com/jaredzhou/moonpg)。

## 开发

```bash
moon check --target native      # 类型检查
moon test  --target native      # 跑测试（6 个）
moon fmt && moon info           # 格式化 + 生成 pkg.generated.mbti
```

Turso 的动态库已复制到仓库内 `libs/`（附 `.sha256`），`moon.pkg` 与 `ffi/moon.pkg` 的 `-L`/rpath 都指向它，
所以测试不需要 `LD_LIBRARY_PATH`。换机器或换仓库位置时跑一次：

```bash
bash scripts/fetch-turso-lib.sh   # 复制库 + 重写两处链接路径
```

目录：

| 路径 | 内容 |
| --- | --- |
| `mturso.mbt` | 公开 API：`Database`、`Connection`、`TursoError` |
| `ffi/` | FFI 层：`extern "c"` 声明 + C stub（每连接一个工作线程、门铃 pipe）+ vendored `turso.h` |
| `design/` | 下一版 API 的设计稿（`declare` 声明 + 用法片段，可 `moon check`） |
| `libs/` | Turso 的 C 动态库 |
| `notes/` | Turso 引擎的研究笔记（源码走读、Go SDK 实测、绑定开发参考），与库 API 无关 |
| `examples/` | Go SDK 示例、C ABI 工作线程骨架（研究用） |

## License

Apache-2.0
