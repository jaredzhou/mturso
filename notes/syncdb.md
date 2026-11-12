# syncdb 设计与实现规划

状态：外部 server 的客户端主路径已实现（bootstrap / push / pull / checkpoint / stats，tickets #14-#17）；自研 server 已提供 `/v2|v3/pipeline`、`/v3/cursor` 和官方 Go SDK 兼容的 SQL pipeline（ticket #19），同步协议的 bootstrap / pull / push 仍待实现。Turso 版本基线为 **v0.8.2**。

## 目标

在现有本地 Turso 绑定之上增加 `SyncDatabase`：

- 本地读写仍然通过普通 SQL 接口完成；
- 显式提供 `push`、`pull`、`checkpoint`、`stats`；
- 支持 Turso Cloud 和本地 `tursodb --sync-server`；
- 第一阶段由 `SyncServer` 管理外部 server，后续实现协议兼容的自研 server；
- Windows x64 与 Linux x86_64 都必须通过端到端同步测试。

第一阶段只做全量同步和单数据库，不开放 partial sync、远端加密、namespace、多数据库 `--sync-dir`。

## 证据

### 官方文档

- <https://docs.turso.tech/sync/usage>：首次 bootstrap、`push` 后推覆盖、`pull` 返回是否变化、checkpoint 与 stats。
- <https://docs.turso.tech/sync/local-sync-server>：本地 server 与 Cloud 使用同一协议，开始时不需要 token。
- <https://docs.turso.tech/sync/checkpoint>：sync 数据库禁用自动 checkpoint，必须显式执行。
- <https://docs.turso.tech/sync/conflict-resolution>：last-push-wins；pull 使用回滚、应用远端、重放未推送本地变更。

### Go v0.8.2

来源：Go module `turso.tech/database/tursogo@v0.8.2`：

- `driver_sync.go`：`NewTursoSyncDb`、`Connect`、`Push`、`Pull`、`Stats`、`Checkpoint`。
- `Pull` 实际执行 `wait_changes → apply_changes`。
- 所有同步操作由同一个 mutex 串行化。
- `driveOpUntilDone` 反复调用 `turso_sync_operation_resume`，遇到 `TURSO_IO` 就处理 I/O queue。
- 同步 SQL 连接会附带 `processOneIo`，在 `turso_statement_run_io` 前推进 sync engine I/O。

### Rust v0.8.2

来源：`tursodatabase/turso` tag `v0.8.2`：

- `sync/sdk-kit/turso_sync.h`
- `sync/sdk-kit/src/{capi,rsapi,sync_engine_io,turso_async_operation}.rs`
- `sync/engine/src/database_sync_operations.rs`
- `cli/sync_server.rs`

本地 server 暴露 `/v2/pipeline`（JSON）和 `/pull-updates`（protobuf）。Rust server 使用 core 内部 WAL frame、MVCC logical log 等能力；这些能力没有出现在当前绑定的 `ffi/turso.h` 中，因此 C 阶段需要 native server bridge。

### 本机测量

`dumpbin /exports libs/turso_sync_sdk_kit.dll` 确认当前 DLL 导出 29 个 `turso_sync_*` 符号，包括 database new/open/create/connect、push、wait/apply、checkpoint、stats、operation resume 与 I/O item API。

MoonBit core 当前已提供 HTTP/HTTPS/TLS 客户端和 HTTP/TLS server 包，可作为同步 I/O driver 与 C 阶段 server 的实现基础。

## 公开 API

`Database` 保持现名和现有 API。同步库使用独立 facade：

```moonbit
pub struct SyncDatabase { ... }

async fn SyncDatabase::open(config : SyncConfig) -> SyncDatabase raise TursoError
async fn SyncDatabase::connect(self : SyncDatabase) -> Connection raise TursoError
async fn SyncDatabase::push(self : SyncDatabase) -> Unit raise TursoError
async fn SyncDatabase::pull(self : SyncDatabase) -> Bool raise TursoError
async fn SyncDatabase::checkpoint(self : SyncDatabase) -> Unit raise TursoError
async fn SyncDatabase::stats(self : SyncDatabase) -> SyncStats raise TursoError
fn SyncDatabase::close(self : SyncDatabase) -> Unit
```

`SyncConfig` 首版包含：

- `path`
- `remote_url`
- `auth_token?`
- `client_name?`
- `long_poll_timeout_ms?`
- `bootstrap_if_empty?`
- `max_conns?`

默认 `bootstrap_if_empty = true`、`max_conns = 4`，并要求 long-poll timeout 有有限上限。

`SyncDatabase` 和普通 `Database` 都返回同一个公开 `Connection`。底层同步连接与普通连接均为 `turso_connection_t`，prepare/bind/step/rows/事务 ABI 相同。`Connection` 不公开 owner 类型；它持有私有的归还与关闭检查 callback。同步 facade 首版拥有自己的连接池，公共池实现以后按实际重复再抽取。

## 客户端执行模型

每次同步操作遵循：

```text
create operation
  loop
    resume
    TURSO_OK   -> continue
    TURSO_IO   -> drain sync I/O queue, complete HTTP/full-read/full-write
    TURSO_DONE -> extract typed result and finish
```

`push / pull / checkpoint / stats` 由 async mutex 严格串行。第一版不支持 operation cancel；long poll 必须有有限 timeout，清理路径用 cancel protection 包住。

`pull` 只公开高层操作，返回是否应用了变化。底层 `wait_changes` 和 `apply_changes` 保持私有。若没有 changes，返回 `false`。

同步 SQL 连接不能直接沿用现有普通查询 worker：官方 Go driver 在 `TURSO_IO` 时先处理 sync I/O queue，再调用 core `run_io`。实现必须保留 worker thread 的事件循环非阻塞性，并为 sync worker 增加私有 I/O 请求/完成桥，不能静默忽略这些请求。

## 错误

扩展现有 `TursoError`：

```moonbit
TursoError::SyncError(SyncErrorKind, String)

enum SyncErrorKind {
  Network
  Auth
  Protocol
  RemoteBusy
  RemoteConflict
  Internal
}
```

普通 SQL 的 `Busy` / `Conflict` 语义保持不变。同步操作仍只在一个 `TursoError` 错误族里传播。

## SyncServer

### A 阶段

```moonbit
async fn SyncServer::start(config : SyncServerConfig) -> SyncServer
async fn SyncServer::stop(self : SyncServer) -> Unit
fn SyncServer::base_url(self : SyncServer) -> String
```

- 从 `TURSODB` 或 `PATH` 查找 `tursodb` 并校验 v0.8.2；
- 只允许 loopback、明文 HTTP、无鉴权；
- 启动后健康检查成功才返回；
- `stop()` 幂等并等待子进程退出；
- CI 下载固定版本，不提交大型可执行文件。

### C 阶段

- 与官方 Turso clients 兼容 `/v2/pipeline` 与 `/pull-updates`；
- 增加 native server-engine bridge，补齐当前 C ABI 未暴露的 WAL/MVCC 能力；
- 默认 loopback；
- 非 loopback 绑定必须同时开启 HTTPS 和鉴权；
- TLS 使用显式 certificate/private-key 文件；
- 鉴权先支持静态 Bearer token，并预留 verifier callback；
- 不实现 ACME、自动签发、用户系统、scope 或多租户。

## 关闭语义

`SyncDatabase::close()` 在 MoonBit 单线程 async 运行时不阻塞事件循环：

1. 标记 closed，拒绝新同步操作和连接 checkout；
2. 若当前没有 operation，立即 finalize；
3. 若已有 operation 在飞，由该 operation 的退出路径在结束后关闭所有 idle/busy SQL 连接并 deinit sync engine；
4. 多条退出路径用 finalized 标志保证幂等。

`SyncServer::stop()` 与数据库关闭独立，先停止接受请求，再等待 server 结束。

## 测试

只通过公开 API 测试：

1. bootstrap：空副本从远端取得 schema/data；
2. A 本地写入并 `push`，B `pull` 后可见；
3. B 离线写入但未 push，A 推远端变化，B `pull` 后验证回滚/拉取/重放；
4. `pull` 无变化返回 false；
5. `push / pull / checkpoint / stats` 并发调用被串行化；
6. stats 的 revision、WAL size、网络字节与时间字段可观测；
7. checkpoint 后 main WAL 大小下降；
8. server start/stop、端口冲突、错误版本、子进程早退；
9. close 等待 active sync operation，并安全释放连接；
10. Windows x64、Linux x86_64 完整跑同一套测试。

真实 Turso Cloud 仅在有 token 时执行可选 smoke test。

## Tickets

GitHub Issues 保存可执行切片和 native blocking edges：

- [#12](https://github.com/jaredzhou/mturso/issues/12) — `Connection` 按来源归还。
- [#13](https://github.com/jaredzhou/mturso/issues/13) — 启动和停止本地 Turso sync server。
- [#14](https://github.com/jaredzhou/mturso/issues/14) — bootstrap 并查询 sync database。
- [#15](https://github.com/jaredzhou/mturso/issues/15) — push 本地已提交变更。
- [#16](https://github.com/jaredzhou/mturso/issues/16) — pull 远端变化并重放本地变更。
- [#17](https://github.com/jaredzhou/mturso/issues/17) — checkpoint 和同步统计。
- [#18](https://github.com/jaredzhou/mturso/issues/18) — 跨平台同步验收门禁。
- [#19](https://github.com/jaredzhou/mturso/issues/19) — 自研 server 提供 SQL pipeline。
- [#20](https://github.com/jaredzhou/mturso/issues/20) — 官方 client 从自研 server bootstrap。
- [#21](https://github.com/jaredzhou/mturso/issues/21) — 自研 server 支持增量 pull。
- [#22](https://github.com/jaredzhou/mturso/issues/22) — 自研 server 支持 push。
- [#23](https://github.com/jaredzhou/mturso/issues/23) — 自研 server 的安全公网模式。
