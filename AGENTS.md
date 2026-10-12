# AGENTS.md

## Agent skills

### Issue tracker

Issues 和 spec 都在 GitHub Issues（`jaredzhou/mturso`），用 `gh` CLI 操作。见 `docs/agents/issue-tracker.md`。

### Triage labels

五个默认标签（`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` / `wontfix`）。见 `docs/agents/triage-labels.md`。

### Domain docs

single-context：根目录 `CONTEXT.md` + `docs/adr/`。见 `docs/agents/domain.md`。

本仓库是一个 **Turso 研究仓库**，目标是搞清楚两件事：

1. **用法（usage）**：在本地跑 Turso 引擎 / SQL shell，并通过客户端 SDK 访问（首个目标是 **Go SDK**）。
2. **实现（implementation）**：阅读并总结引擎源码的实现方法（存储、WAL、MVCC、向量检索、全文索引、同步、MCP 等）。

背景：Turso 是 **SQLite 的 Rust 重写**，上游仓库为 `github.com/tursodatabase/turso`（早期代号 *limbo*，代码里仍能看到 `limbo_*` 符号）。它与 SQLite 的文件格式/语法高度兼容，并在其上叠加了一批实验特性。

## 这个仓库同时是 `jaredzhou/mturso`（Turso 的 MoonBit 绑定）

- 模块名 `jaredzhou/mturso`（`moon.mod`），**native-only**（链接 Turso 的 C ABI）。
- `mturso.mbt` 是 facade；**FFI 单独成包**：`ffi/`（`ffi.mbt` 放 `extern "c"` 声明、`stub.c` 是 C 实现、`turso.h` 是 vendored 的 C ABI 头）。
- 现状：`Database::open` → 多个 `Connection`（`db.connect()`）；`query` / `exec` 是 **async**（每连接一个工作线程 + 门铃 pipe，事件循环不被阻塞），另有 `query_blocking` / `exec_blocking` 同步版本。设计见 `notes/turso-binding-guide.md` §6。
- MoonBit 工具链：**0.1.20260920**（core `0.10.14`），依赖 `moonbitlang/async@0.22.4`。注意 async 0.22.4 需要新的 core（旧 core 缺 `eprintln`）——工具链已用 `moon upgrade` 升过。
- 改动 FFI 或 C stub 后必须跑：`moon check --target native`、`moon test --target native`；收尾跑 `moon fmt && moon info`（检查 `pkg.generated.mbti` 的 diff）。

## 环境（2026-10-11 实测，改动前请复验）

- **tursodb 0.8.2**：`/home/jared/.turso/tursodb`（已加入 `PATH`，通过 `~/.turso/env`）。它**既是引擎也是交互式 SQL shell**。
  - `select sqlite_version();` 返回 `3.50.4`。这是**兼容性伪装**，并不代表它是 SQLite。
- **Go**：`go1.27.1`（原 1.26.4；因 `kelindar/search/llama` 要求 go 1.27，已 `go env -w GOTOOLCHAIN=go1.27.1` 升级），`GOPROXY=https://proxy.golang.org,direct`。
- **网络：沙箱内默认阻断**（`go get` / `git clone` / 下载都失败，代理端口也 `operation not permitted`），但**提权（`require_escalated`）后可访问外网**。需要联网的步骤要么提权执行，要么在笔记里标注为「待联网验证」。
- 本地已有：turso 源码副本（`/tmp/turso-src`，tag **v0.8.2**，`scripts/fetch-source.sh` 可重拉）、Go 模块缓存里的 `turso.tech/database/tursogo`（**v0.8.2**）与预编译原生库、RAG 资源（`.cache/rag/` 下的 MiniLM GGUF + 本地编译的 `libllama_go.so`）。
- 本地已有（MoonBit 相关）：`moonbitlang/async` **v0.22.4** 源码副本（`/tmp/async-0224`，tag `v0.22.4`，`git clone --branch v0.22.4 https://github.com/moonbitlang/async` 可重拉）；`moon` 工具链在 `/home/jared/.moon/bin/moon`。用户自己的 PG 驱动工程在 `/home/jared/projects/moonpg`（pin 的是 `moonbitlang/async@0.19.0`，**不要擅自升级它的依赖**）。
- 本地仍没有：`turso` 云 CLI、`sqlite3` 二进制。
- 沙箱会拒绝 `rm -f` 之类的破坏性命令；用 `mktemp -d` 建临时目录，清理交给用户。

## 目录约定

- **MoonBit 模块（根目录）**：`moon.mod`（模块名 `jaredzhou/mturso`）、`moon.pkg`（根包 + 最终链接参数）、`mturso.mbt`（facade）、`mturso_test.mbt`（黑盒测试）、`pkg.generated.mbti`（`moon info` 生成，要提交）。
- `ffi/` —— **独立的 FFI 子包**：`moon.pkg`（native-stub + link）、`ffi.mbt`（raw `extern "c"`）、`stub.c`（C 实现）、`turso.h`（vendored C ABI 头）、`pkg.generated.mbti`。
- `libs/` —— 仓库内的 Turso C 动态库（`libturso_sync_sdk_kit.so`，**20MB**）+ 它的 `.sha256`。链接路径由 `scripts/fetch-turso-lib.sh` 写入 `moon.pkg`；换机器或换仓库位置就跑那个脚本。（不想把 20MB 放进版本库的话，把 `libs/` 加进 `.gitignore`，用脚本按需拉取。）
- `_build/` —— MoonBit 构建产物，**不要提交**（已在 `.gitignore`）。
- `notes/` —— 研究笔记，**一个主题一个文件**（`architecture.md`、`source-walkthrough.md`、`go-sdk.md`、`turso-binding-guide.md`）。
- `examples/` —— 可直接运行的示例；`examples/tursodb-basics.sh`（CLI）、`examples/go-sdk/`（Go SDK）、`examples/c-abi-worker/`（C ABI 的「工作线程 + 门铃」最小骨架，150 行，已实测）。
- `scripts/` —— 辅助脚本：`fetch-source.sh`（克隆对齐版本的引擎源码）、`fetch-rag-assets.sh`（模型）、`fetch-rag-corpus.sh`（英文语料）、`fetch-rag-corpus-zh.sh`（中文语料）、`build-llama-lib.sh`（原生 embedding 库）。
- 根目录放 `AGENTS.md`、`README.md`。
- 临时数据库一律放 `mktemp -d` 出来的目录里，**不要提交 `*.db` / `*.db-log` / `*.db-wal` 等文件**。
  Go 相关产物（`examples/go-sdk/*.db`、模块缓存）也不要提交。

## 常用命令（均已实测）

```bash
# --- MoonBit 绑定（jaredzhou/mturso）---
moon check --target native                  # 类型检查
moon test  --target native                  # → Total tests: 1, passed: 1
moon fmt && moon info                       # 格式化 + 生成 pkg.generated.mbti

# 版本
/home/jared/.turso/tursodb --version            # Turso 0.8.2

# 内存库执行一条 SQL
/home/jared/.turso/tursodb :memory: "select 1+1;"

# 文件库执行多条 SQL（默认 pretty 表格输出）
d=$(mktemp -d)
/home/jared/.turso/tursodb "$d/demo.db" \
  "create table t(id integer primary key, name text);
   insert into t(name) values ('alice'),('bob');
   select * from t;"

# 输出模式：pretty（默认）/ list / line
/home/jared/.turso/tursodb -m list :memory: "select 1 as a, 2 as b;"

# 交互式 shell 的元命令（. 开头）
printf '.help\n.quit\n' | /home/jared/.turso/tursodb "$d/demo.db"

# 完整示例
bash examples/tursodb-basics.sh
```

其他运行形态：`--mcp`（内置 MCP server）、`--sync-server <addr>` / `--sync-dir <path>`（同步服务）、`-v/--vfs <io_uring|memory|syscall>`。这些会**监听端口或加载本地文件**，除非有明确任务否则不要启动。

## 研究约定

- 每条关于「内部实现」的结论都要**可追溯**：要么给出源码路径，要么给出获取该结论的命令（例如从二进制里提取字符串的证据）。
- 笔记里区分三档：**实测**（跑过）、**源码/二进制证据**（引用了路径或命令）、**推测**（明确写「推测」）。无法验证的标 `TODO(待验证)`。
- 示例脚本必须能直接 `bash` 跑通；跑不通的示例不要放进 `examples/`。
- 检索文本/文件名优先用 `rg`。

## 研究路线图（backlog）

- **Go SDK** ✅：模块是 `turso.tech/database/tursogo`（驱动名 `turso`）。综合示例 `examples/go-sdk/`（子命令 `basic` / `cdc` / `vector` / `concurrent` / `mvcc` / `conflict` / `retry` / `sync` / `rag`）已全部跑通，覆盖 CDC、WAL 并发写对照（含单连接基线、忙等待开关、易主与 CPU 开销实测）、MVCC `BEGIN CONCURRENT` 与写写冲突语义、重试预算实测、向量检索、本地 `tursodb --sync-server` 的 push/pull/checkpoint/stats、以及 RAG。待办：Turso Cloud 真实远端 + token、`experimental=` / `async=1` / 加密选项的实测。
2. **源码通读** ✅（第一遍）：已在 tag v0.8.2 上按管线总结（解析 → translate → VDBE → 执行）与存储/并发层，见 `notes/source-walkthrough.md`。
3. **特性深挖**（进行中）：向量检索、FTS（基于 tantivy）、JSON/JSONB、自定义类型、物化视图（incremental/DBSP）、CDC、静态加密、同步协议、MCP server、Postgres 前端。
4. **RAG 演示** ✅：`examples/go-sdk/` 的 `rag` 子命令 —— 本地 embedding 模型对真实文章（古腾堡，公有领域）分块嵌入 → 存入 Turso 向量 → 最近邻检索 → 组装上下文。支持中英：英文用 MiniLM-L6-v2（`data/`），中文用 bge-small-zh-v1.5（`data-zh/`）。

## 注意 / Gotchas

- **MoonBit 链接参数要挂在「会做最终链接的那个包」上**：`ffi/moon.pkg` 的 `link` 只影响它自己参与链接时；`moon test` 的最终链接发生在根包，所以 `cc-link-flags`（`-L`/`-l`/`-Wl,-rpath`）**同时写在根 `moon.pkg`**。已带 rpath，所以测试不需要 `LD_LIBRARY_PATH`。
- Turso 的 C 动态库已复制到仓库内 `libs/`（源头是 Go SDK 的分发包 `turso-go-platform-libs@v0.8.2`；`nm -D` 可确认它导出 77 个 `turso_*` 符号）。`moon.pkg` / `ffi/moon.pkg` 里的 `-L` 与 rpath 都指向 `libs/`，**换机器或换仓库位置要重新跑 `scripts/fetch-turso-lib.sh`**（它会重写这两处路径）。
- C 侧约定（`ffi/stub.c`）：**从不向 MoonBit 返回 NULL**（失败通过 `mturso_last_error()` 报，空串=成功）；句柄是外部对象 + finalizer；**同一个语句不要混用 `step` 和 `execute`**。
- MoonBit 侧：**不能给别的包的类型加方法**（`Cannot define method ... for foreign type`）——所以 facade 自己定义 `pub struct Conn` 包住 `@ffi.Conn`。
- **网络被阻断**：不要设计依赖联网的步骤而不加说明。
- Go 构建缓存默认在 `~/.cache/go-build`（沙箱内不可写）：跑 Go 示例时用 `GOCACHE=/tmp/gocache go run .`。
- `go build ./...` 可能报 `error obtaining VCS status`（因为 `.git` 是空目录）：加 `-buildvcs=false`。
- `tursodb` 是预览版引擎，大量特性藏在 `--experimental-*` 开关后面（views、custom-types、vacuum、attach、without-rowid、multiprocess-wal 等），**不要假设与 SQLite 生产级等价**。
- 仓库目前**还不是一个真正的 git 仓库**：`.git/` 为空目录且属主不可写。需要版本管理时先与用户确认（`git init` 可能因目录权限失败）。
- 不要把 `--sync-server` / `--mcp` 绑定到对外地址。
