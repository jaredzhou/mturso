# turso 研究仓库

## 这是 `jaredzhou/mturso`：Turso 的 MoonBit 绑定

模块名 `jaredzhou/mturso`，基于 Turso 官方 C ABI（`sdk-kit/turso.h`），native 目标。

### 当前状态

`Database` → 可开**多个** `Connection`；`query` / `exec` 是 **async**（语句在每连接的工作线程上执行，
事件循环不被阻塞），另有 `query_blocking` / `exec_blocking` 同步版本可用（不需要 async 运行时）。

```moonbit
let db = @mturso.Database::open(":memory:")
let c1 = db.connect()
let c2 = db.connect()          // 一个库可以开多个连接

c1.exec("create table t(id integer primary key, v integer)")
c1.exec("insert into t(v) values (1), (2)")
let rows = c2.query("select id, v from t")   // "1\t1\n2\t2"

c1.close(); c2.close(); db.close()
```

**并发模型（已实测）**：每条连接自带一个工作线程 + 一个「门铃」pipe。`query` 提交后把语句交给工作线程
（阻塞只发生在那里），完成后工作线程往 pipe 写 1 字节，MoonBit 侧 `RawFdStream::read` 挂起等待 ——
**事件循环线程全程可以继续跑别的任务**。

绑定还顺带在每个连接上注册了标量函数 **`mt_sleep(ms)`**（测试/诊断用）：它在**执行该语句的线程**上睡眠，
所以可以直接在 SQL 里制造一个慢查询。实测（`moon test --target native` 的输出）：

```
慢查询 select mt_sleep(2000) 返回用时 2001ms；快查询 select 6*7 返回用时 1ms
```

两条 SQL 在**不同连接**上并发执行：慢查询在里面睡满 2 秒，200ms 后发出的快查询 **1ms 就返回了**，
没有被慢查询挡住。

### 编译与测试（已实测）

```bash
moon check --target native      # 类型检查
moon test  --target native      # → Total tests: 1, passed: 1
moon fmt && moon info           # 格式化 + 生成 pkg.generated.mbti
```

依赖 Turso 的 C 动态库，已经**复制到仓库内 `libs/`**（20MB，附 `.sha256`）。
`moon.pkg` 和 `ffi/moon.pkg` 里的 `-L` / rpath 都指向它，所以测试**不需要设 `LD_LIBRARY_PATH`**。
换机器或换仓库位置时重新跑一次：

```bash
bash scripts/fetch-turso-lib.sh   # 复制库 + 重写两个 moon.pkg 的链接路径
```

### 目录

| 路径 | 内容 |
| --- | --- |
| `mturso.mbt` | facade：`Database`、`Connection`、`MtursoError`；`open/connect`、`query`/`exec`（async）、`query_blocking`/`exec_blocking`、`close` |
| `ffi/` | **独立子包**：`extern "c"` 声明（`ffi.mbt`）+ C stub（`stub.c`）+ vendored `turso.h` |
| `notes/turso-binding-guide.md` | 设计笔记：为什么这样分层、并发/async 的坑 |
| `examples/` | Go SDK 示例 + C ABI 工作线程骨架 |

### 下一步（TODO）

- [ ] 参数绑定（现在只能把字面量写进 SQL，没有 `bind` 参数）；
- [ ] 结果类型化（现在只返回制表符分隔文本，`BLOB` 显示为 `<blob>`，`NULL` 显示为 `NULL`）；
- [ ] 取消/超时：任务被取消时要与工作线程的门铃对齐，避免残留字节导致后续读错位；
- [ ] Turso 特有扩展：`BEGIN CONCURRENT`、CDC、向量检索、sync。

---

## 研究笔记部分

用来研究 [Turso](https://turso.tech) 的**用法**与**底层实现**。

Turso 是 SQLite 的 Rust 重写（上游 `github.com/tursodatabase/turso`，早期代号 *limbo*）：兼容 SQLite 文件格式与 SQL 方言（`sqlite_version()` 报 3.50.4），并在其上增加了向量检索、全文索引、JSON/JSONB、自定义类型、物化视图、MVCC、静态加密、同步与 MCP server 等能力。

## 本地已装好的东西

- `tursodb` **0.8.2** —— 引擎 + 交互式 SQL shell，路径 `/home/jared/.turso/tursodb`（已在 `PATH`）。
- Go **1.26.4**。

## 快速开始

```bash
# 一条 SQL
tursodb :memory: "select 1+1;"

# 建表 + 查询（用临时目录，别把 .db 提交进仓库）
d=$(mktemp -d)
tursodb "$d/demo.db" \
  "create table t(id integer primary key, name text);
   insert into t(name) values ('alice'),('bob');
   select * from t;"

# 内置示例脚本（已实测）
bash examples/tursodb-basics.sh
```

## 工作区结构

| 路径 | 内容 |
| --- | --- |
| `AGENTS.md` | 给编码 agent 的仓库说明：环境、约定、命令、路线图、坑 |
| `notes/architecture.md` | 引擎底层实现速览（存储 / WAL / MVCC / 各扩展） |
| `notes/source-walkthrough.md` | 源码走读（tag v0.8.2）：编译管线、异步 I/O 模型、存储格式、MVCC |
| `notes/go-sdk.md` | Go SDK 接入笔记（已实测） |
| `notes/turso-binding-guide.md` | 绑定开发参考：Go SDK 实测笔记全文 + C API / MoonBit FFI 映射 + 与 `jaredzhou/moonpg` 对齐的接口设计 |
| `examples/tursodb-basics.sh` | 可直接运行的 `tursodb` 基础示例 |
| `examples/go-sdk/` | 官方 Go SDK（`turso.tech/database/tursogo`）综合示例：`basic`/`cdc`/`vector`/`concurrent`/`mvcc`/`sync`/`rag`（RAG 支持中英文语料） |
| `scripts/fetch-source.sh` | 克隆与本地引擎对齐的 Turso 源码（默认 tag v0.8.2） |
| `scripts/fetch-rag-*.sh`、`build-llama-lib.sh` | RAG 演示所需的模型 / 中英语料 / 原生 embedding 库 |

## 现状与限制

- **网络在沙箱内默认阻断**，但提权后可访问外网，所以拉依赖 / clone 源码需要提权执行一次。
- **Go SDK 已跑通**：`turso.tech/database/tursogo`（驱动名 `turso`）；跑示例用 `cd examples/go-sdk && GOCACHE=/tmp/gocache go run .`。
- **源码已就位**：`/tmp/turso-src`（tag v0.8.2）。
- 仓库尚未初始化 git（`.git/` 为空且不可写），需要时请先确认。
