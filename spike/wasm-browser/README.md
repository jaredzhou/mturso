# spike: MoonBit(wasm) × Turso —— 能不能在浏览器里跑起来

（这是 **prototype**，回答 issue #10 的问题，不是生产代码。）

## 结论

**能做，而且已经在 Node 里端到端跑通了**（MoonBit 编译成 wasm，驱动真正的 Turso 引擎）。
浏览器版是把同样两个 worker 换成 Web Worker + `@tursodatabase/database-wasm`；本机没有浏览器，
所以浏览器那一趟需要你在本地打开验证（见文末）。

四个问题的答案：

**1. 哪条路？直接在 MoonBit 里编译可行吗？**

不是"把 Turso 编进 MoonBit"，而是 **MoonBit 编成 wasm1（`--target wasm`），通过宿主提供的导入函数
调用 Turso**。实测：

- `extern "js"` 在 **wasm-gc 下不支持**（编译器直接报 `extern "js" is unsupported in wasm-gc backend`）；
  可用的是 `wasm`（wasm1）目标上的 `extern "wasm" fn f(...) = "模块名" "函数名"`，宿主注入实现。
- 跨界 ABI 实测结果：`Bytes` 参数在宿主侧是**数据指针**（`ptr+0` 就是内容，`ptr-4` 是长度），
  配 `export-memory-name` 导出内存后宿主可读写；`FixedArray[Byte]` 同样可以当输出缓冲写回。
- 一个只带我们的导入、**零运行时导入**的 wasm 模块（`WebAssembly.Module.imports` 只有一个 `mturso.probe`），
  在 Node 里实例化即跑。
- MojnBit 的 wasm 包必须在**独立 module** 里：主仓库的包是 `supported_targets = "+native"`，
  同一个 module 里没法给 wasm 目标建包（构建计划阶段就报 "does not support target backend"）。

**2. wasm 里没有线程，异步怎么办？**

Turso 的 JS API **只有异步版**（实测 `prepare().all()` / `exec()` 全返回 Promise，没有 `Sync` 变体），
浏览器包本身还把引擎放在它自己的内部 Worker 里。而 MoonBit 的 wasm 模块是同步的。

解法（已实测）：**两个 worker + SharedArrayBuffer**。MoonBit + 宿主 shim 跑在 worker A（同步、用
`Atomics.wait` 阻塞自己），Turso 跑在 worker B（异步、event loop 保持活着）。A 发请求 → `Atomics.wait`
→ B 算完写进 SAB 并 `Atomics.notify` → A 取结果返回。注意 `Atomics.wait` **在浏览器主线程上非法**，
所以 MoonBit 侧天生就得在 worker 里 —— 这条约束直接决定了 API 形状（见下）。

**3. facade 还能复用吗？**

类型面（`Value` / `Column` / `Row` / `Rows` / `ToValue` / `FromValue` / `FromRow` / `QueryExecutor` /
错误）都是纯 MoonBit，**与目标无关，可以复用**。要动的是包结构：

- 现在 facade 和 native FFI 在同一个包（根包 import `ffi/`，整包 native-only），wasm 没法用它；
- 建议拆成「target 无关的 core 包（类型 + trait + 错误）」+「每个目标一个 backend 包」，
  根包按目标 re-export。这样 `Connection::query` 的语义（TSV 文本 / 行集）在两个目标上一致。
- 宿主契约也可以照抄 native stub 的形状（`exec` / `result_len` / `result_copy` / `log`），
  所以 backend 之间的差异被压到很小。

**4. 体积与内存**

- Turso 的浏览器包 `@tursodatabase/database-wasm@0.8.2`：整包 15.6 MB（`bundle/main.es.js`，wasm 以
  base64 内联），裸 wasm `dist/turso.wasm32-wasi.wasm` **11.6 MB**；
- 我们自己的 MoonBit wasm 模块（这个 spike）**≈ 10 KB**；
- 也就是说端侧体积基本由 Turso 决定，MoonBit 这层可以忽略。

## 另一个重要发现：Turso 的 wasm 是 NAPI/JS 形态，不是 C ABI

`dist/turso.wasm32-wasi.wasm`（11.6 MB）导入 `env` + `wasi_snapshot_preview1`，导出的是
`__napi_register__*` / `emnapi_async_worker_*`（napi-rs + emnapi），**没有导出 `turso_*` C ABI**。
所以"让 MoonBit 直接 import 那些 C 函数"这条路目前不存在。两条可选：

1. **走 JS 桥**（本 spike 的路线）：宿主用官方的 `@tursodatabase/database-wasm`，MoonBit 通过
   `extern "wasm"` 导入函数调它。快，但依赖 JS 生态，且要处理上面说的同步/异步边界。
2. **自己编 sdk-kit 到 wasm32**：`sdk-kit/Cargo.toml` 已经为 `target_family = "wasm"` 关掉了编不了的依赖，
   理论上能出一个导出 `turso_*` 的 wasm32 模块；那样 MoonBit 的宿主 shim 可以非常薄（直接转发 C ABI），
   和 native 的 stub 几乎同形。代价是要维护一条 Rust→wasm 的构建链。

## 怎么跑

```bash
cd spike/wasm-browser
npm install

# (1) 两趟回放版：MoonBit wasm 驱动真 Turso（简单，先看这个）
node host-node.mjs

# (2) 两线程版：验证「同步 MoonBit ⇄ 异步 Turso」的阻塞边界（浏览器就是这个形状）
node host-worker-model.mjs

# 重新编 MoonBit 侧
cd moonbit && moon build --target wasm
```

`host-worker-model.mjs` 的实际输出：

```
=== MoonBit (wasm) -> Turso ===
1	alice	revkjavik
2	bob	shanghai
2
42
[worker A] mt_demo 返回，总耗时 18ms
```

## 浏览器版（需要你本地验证）

本机没有任何浏览器（`google-chrome` / `chromium` / `firefox` 都不在），也没法 sudo 装，
所以 `browser/` 那套我**没能实测**。结构是 Node 版的机械移植：
`browser/index.html` 起两个 Web Worker，A 跑我们的 wasm（`Atomics.wait` 合法），B 跑 Turso 的浏览器包。

```bash
cd spike/wasm-browser
python3 -m http.server 8123      # 必须走 http（wasm 模块不能从 file:// 加载）
# 打开 http://localhost:8123/browser/
```

如果打不开，按这三处先查：① `node_modules/@tursodatabase/database-wasm` 是否装好；
② Worker A 里取的 wasm 路径（`moonbit/_build/wasm/debug/build/mturso-wasm-spike.wasm`）是否存在；
③ Turso 浏览器包的内部 worker 是否被 http 服务器正确返回（它的 wasm 是 fetch 加载的）。

## 这个 spike 建议的后续切片

1. **拆包**：把 target 无关的类型/trait 抽成 core 包（纯 MoonBit，两个目标共用），先落 native 的 backend。
2. **wasm backend（JS 桥路线）**：宿主 shim 实现和 native stub 同形的契约，MoonBit 侧只换 backend；
   明确定义 `Database`/`Connection` 在 wasm 下的执行模型（worker A 同步阻塞，Worker B 异步）。
3. **（可选）自己编 sdk-kit 到 wasm32**：如果不想依赖 JS 生态，走这条；两条路线在 MoonBit 侧长得一样。
4. 体积/内存实测补充：真正打包一个端侧页面，量首屏加载（11.6 MB 裸 wasm vs 15.6 MB 内联包）。
