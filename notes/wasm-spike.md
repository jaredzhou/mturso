# WASM / 端侧支持 spike

状态：最小端到端原型已跑通；还不是可发布的 WASM API。

固定版本：

- Turso `v0.8.2`，commit `5c168be5ef6a32ac966daf5983502a4f694b37ad`
- `@tursodatabase/database-wasm@0.8.2`
- Node `22.22.0`
- MoonBit `0.1.20261029`，target `wasm`

可复核 demo：

```bash
cd spike/wasm-browser
npm install
npm run run
```

实测输出：

```text
=== mturso wasm spike ===
1	alice
2	bob
42
```

这不是硬编码结果。MoonBit wasm 发起 SQL，Node 宿主驱动 Turso wasm，
然后把真实行数据复制回 MoonBit 的线性内存。

## 结论

第一版走：

```text
MoonBit target=wasm（线性内存）
  + JS 宿主桥
  + @tursodatabase/database-wasm
```

不选 `wasm-gc`，也不直接把 `sdk-kit` 的 C ABI 编成第二个 wasm 模块。

原因：

1. Turso 现有的浏览器产物是 `wasm32-wasip1-threads`，入口是 JavaScript/NAPI，
   不是稳定导出的 C ABI。
2. `@tursodatabase/database-wasm` 已经处理了 WASI、OPFS、SharedArrayBuffer、
   worker 和 NAPI wasm runtime。
3. MoonBit `wasm` 可以用自定义 `extern "wasm"` 导入宿主函数，并用纯线性内存
   ABI 传 SQL/结果。
4. `moonbitlang/async@0.22.4` 的 `wasm-gc` 支持仍未完成。其
   `README.md` 中 `wasm-gc` 项未勾选，`src/internal/event_loop/moon.pkg`
   在 `wasm-gc` 下使用 `unimplemented.mbt`。

## 四个问题的答案

### 1. 目标和 Turso 形态

选 MoonBit `wasm`，不是 `wasm-gc`。

宿主接口是四个很小、同步的 wasm import：

```text
mturso.exec(sql_ptr, sql_len) -> status
mturso.result_len() -> bytes
mturso.result_copy(out_ptr, cap) -> copied
mturso.log(msg_ptr, msg_len)
```

MoonBit 导出内存和 `_start`：

```text
exports:
  memory
  _start
```

证据：

```bash
cd spike/wasm-browser
npm run build
node -e '
  const fs = require("fs")
  const p = "moonbit/_build/wasm/release/build/mturso-wasm-spike.wasm"
  const m = new WebAssembly.Module(fs.readFileSync(p))
  console.log(WebAssembly.Module.imports(m))
  console.log(WebAssembly.Module.exports(m))
'
```

没有直接采用 `sdk-kit` C ABI wasm 的原因不是已经证明它不能编译，而是：

- `sdk-kit/Cargo.toml` 仍以 native/FFI 路径为主；
- 浏览器没有标准的“两个 wasm 模块直接调用”动态链接机制；
- 即使编译出第二个 wasm，仍需要 JS 宿主做内存和函数桥接；
- 官方 JS wasm 包已经包含经过测试的 WASI、OPFS 和 worker 适配。

后续如果要做无 JS hop 的端侧版本，再单独验证 `sdk-kit` 的
`wasm32-wasip1` 构建。当前没有证据支持它比官方 JS wasm 包更可靠。

### 2. 无线程假设和异步模型

“wasm 没有线程”这个前提对当前 Turso 浏览器包不成立。

证据：

- `bindings/javascript/packages/wasm/package.json` 的 NAPI 目标明确写着
  `wasm32-wasip1-threads`；
- `bindings/javascript/packages/wasm/promise-default.ts` 调用
  `initThreadPool()` 并创建 `Worker`；
- `bindings/javascript/src/browser.rs` 使用 SharedArrayBuffer/OPFS
  completion，并导入 `write_async/read_async/sync_async/truncate_async`；
- `examples/javascript/database-wasm-vite/README.md` 要求 COOP/COEP，
  因为需要 SharedArrayBuffer。

本 spike 的执行模型：

```text
MoonBit wasm Worker
  -> 同步 host import exec()
  -> 写入 SharedArrayBuffer，Atomics.wait

Node 主线程
  -> 保持事件循环可运行
  -> await Turso wasm 的 Promise
  -> 写结果，Atomics.notify
```

MoonBit 这一侧表现为“同步查询”，但阻塞的只是 MoonBit 自己的 Worker；
宿主主线程仍能推进 Turso 的异步 I/O。

这带来两个明确限制：

- 不能继续沿用原生版“每个 Connection 一条 worker + pipe”的模型；
- 浏览器必须先满足 COOP/COEP，否则没有 SharedArrayBuffer。

未来的公共 API 可以继续保持 `async fn` 外形，但 wasm backend 内部应当是
一次串行请求，而不是原生池模型。

### 3. facade 是否能复用

`Value`、`ToValue`、`FromValue`、`Row`、`Rows` 的语义可以复用；
native `Database` / `Connection` 的实现不能直接复用。

原因：

- 根包的 native 路径依赖 `@ffi`，而 `ffi` 被门控为 native；
- `Database` 当前持有 `@async.Semaphore`、native DB handle 和连接池；
- Turso 的 JS wasm 包只暴露一个逻辑数据库连接，不能等价映射多个 native
  connection；
- 池统计、每连接 worker、native fd/pipe 在 wasm 下没有对应物。

推荐先新增目标专用的浅层 backend 包，例如 `jaredzhou/mturso/wasm`：

- 只支持 `:memory:`；
- `max_conns=1`；
- 单连接、串行请求；
- 复用值转换和 `Row` 解码；
- 不先模拟多连接池。

等 host 协议稳定后，再把根 facade 的目标实现切过去，避免第一版就引入复杂的
条件编译和两套生命周期状态。

### 4. 体积和内存

实测环境：Linux x86_64、Node 22.22.0、release 构建。

| 产物 | 原始大小 | gzip |
| --- | ---: | ---: |
| MoonBit spike wasm | 8,949 B | 3,620 B |
| `turso.wasm32-wasi.wasm` | 11,612,527 B | 3,895,480 B |
| `wasm-inline.js` | 15,483,678 B | 未测 |
| `bundle/main.es.js` | 15,996,035 B | 未测 |

运行时：

| 指标 | 实测 |
| --- | ---: |
| Turso wasm 线性内存峰值（本 demo） | 276,955,136 B / 264.1 MiB |
| MoonBit wasm 线性内存 | 65,536 B / 64 KiB |
| 查询结束 RSS | 159,997,952 B / 152.6 MiB |
| `/usr/bin/time -v` 最大 RSS | 166,100 KiB / 162.2 MiB |
| 四次请求 demo 端到端时间 | 约 280–345 ms |
| `/usr/bin/time` wall clock | 0.32 s |

Turso 的初始 SharedArrayBuffer memory 请求就是约 258 MiB，查询后增长到约
264 MiB。这个数字是 WebAssembly linear memory 大小，不等于全部已提交 RSS，
但对手机/低内存端侧仍然偏大。

测量命令：

```bash
cd spike/wasm-browser
npm run build
node node-host/bridge.mjs
/usr/bin/time -v node node-host/bridge.mjs
```

`bridge.mjs` 会在 stderr 打印 memory/RSS 指标；`/usr/bin/time -v` 提供峰值 RSS。

## 当前 demo 的边界

- 只有 `:memory:`，没有 OPFS/文件库；
- 只有一个逻辑连接；
- SQL 结果由 JS wrapper 先物化，再复制给 MoonBit；
- 共享结果缓冲固定为 1 MiB；
- demo 只用简单正则区分 SELECT 和 exec；
- 没有参数绑定；
- 没有浏览器实跑，只验证了 Node worker host；
- Node 端使用了 browser Worker 兼容 shim，浏览器本身不需要这个 shim。

因此这不是可以直接发布的 WASM backend。

## 后续实现切片

1. **内存库、单连接、同步 host ABI**
   - 新包 `mturso/wasm`；
   - `open(":memory:")`、`execute`、`query`、参数绑定；
   - 复用 `Value` / `FromValue` / `Row`。

2. **浏览器 host**
   - COOP/COEP；
   - MoonBit wasm 在 Worker；
   - 主线程驱动 Turso wasm；
   - 验证 Chromium/Firefox 的 `select 1`。

3. **流式 pull**
   - 使用 `Statement.iterate()` 而不是 `.all()`；
   - 定义 `HEADER / ROW / END / ERR` 帧；
   - 支持按行拉取和背压。

4. **文件库 / OPFS**
   - 明确浏览器持久化语义；
   - 验证 WAL、并发和关闭；
   - 测量大写入和 cache spill。

5. **统一 facade**
   - 保持 `Connection::query/execute` 的 async 外形；
   - `Database` 在 wasm 下等价于单连接；
   - 暂不承诺多连接池。

## TODO(verify)

- 浏览器 Chromium/Firefox 实跑和启动时间；
- Safari 对 wasm threads/SharedArrayBuffer 的支持；
- 手机上 264 MiB 线性内存是否可用；
- OPFS 文件库和 WAL 的生命周期；
- `sdk-kit` 直接编译到 `wasm32-wasip1` 的体积/ABI/可行性；
- 大结果集和 1 MiB 固定缓冲之外的流式协议成本。
