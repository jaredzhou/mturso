// 线程 A：MoonBit 的 wasm 模块在这里跑。它的查询是同步的，靠 Atomics.wait 阻塞自己，
// 等线程 B（Turso）把结果算好 —— 浏览器里 Atomics.wait 只在 worker 里合法，
// 所以这就是最终架构的形状（MoonBit + 宿主 shim 必须在 worker 里）。

import fs from "node:fs";
import { parentPort, workerData } from "node:worker_threads";

const ctrl = new Int32Array(workerData.sab, 0, 8);
const data = new Uint8Array(workerData.sab);
const SQL_OFF = 64;
const RES_OFF = 64 + 8192;
const RES_CAP = 65536;

const wasmBytes = fs.readFileSync(workerData.wasm);
const decoder = new TextDecoder();
const encoder = new TextEncoder();
const state = { mem: null };
let pending = new Uint8Array(0);

/// 同步等一次查询：把 SQL 交给线程 B，阻塞到自己被唤醒，取回结果。
function syncQuery(sql) {
  const sqlBytes = encoder.encode(sql);
  const n = Math.min(sqlBytes.length, 8192);
  data.set(sqlBytes.subarray(0, n), SQL_OFF);
  Atomics.store(ctrl, 1, n);
  Atomics.store(ctrl, 0, 1);
  Atomics.notify(ctrl, 0);
  // 阻塞直到 B 把 state 置成 2（Atomics.wait 返回 "ok" 或 "not-equal" 都说明状态变了）
  while (Atomics.load(ctrl, 0) !== 2) {
    Atomics.wait(ctrl, 0, 1, 1000);
  }
  const len = Atomics.load(ctrl, 2);
  pending = new Uint8Array(data.subarray(RES_OFF, RES_OFF + len)); // 拷一份，避免被下次覆盖
  Atomics.store(ctrl, 0, 0);
  Atomics.notify(ctrl, 0);
  return 0;
}

const imports = {
  mturso: {
    exec: (ptr, len) =>
      syncQuery(decoder.decode(new Uint8Array(state.mem.buffer, ptr, len))),
    result_len: () => pending.length,
    result_copy: (outPtr, cap) => {
      const n = Math.min(pending.length, cap);
      new Uint8Array(state.mem.buffer, outPtr, n).set(pending.subarray(0, n));
      return n;
    },
    log: (ptr, len) =>
      parentPort.postMessage(decoder.decode(new Uint8Array(state.mem.buffer, ptr, len))),
  },
};

const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
state.mem = instance.exports.memory;
const started = Date.now();
instance.exports._start();
Atomics.store(ctrl, 3, 1);
Atomics.notify(ctrl, 0);
parentPort.postMessage(`[worker A] 程序跑完，总耗时 ${Date.now() - started}ms`);
