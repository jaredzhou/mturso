// spike：验证「同步的 MoonBit(wasm) ⇄ 异步的 Turso」这条边界 —— 两线程 + SharedArrayBuffer。
// 线程 A = MoonBit wasm（同步、会阻塞自己），线程 B = Turso（异步、event loop 保持活着）。
//
// 浏览器版只需把这套换成 Web Worker：A 用我们的 wasm，B 用 @tursodatabase/database-wasm。

import { Worker } from "node:worker_threads";

const SAB = new SharedArrayBuffer(64 + 8192 + 65536);
const wasm = "moonbit/_build/wasm/debug/build/mturso-wasm-spike.wasm";

const turso = new Worker("./worker-turso.mjs", { workerData: { sab: SAB } });
const moonbit = new Worker("./worker-moonbit.mjs", { workerData: { sab: SAB, wasm } });

moonbit.on("message", (m) => console.log(m));
await new Promise((resolve) => moonbit.on("exit", resolve));
await turso.terminate();
