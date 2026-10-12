// 浏览器版线程 A：MoonBit 的 wasm + 宿主 shim。同步查询靠 Atomics.wait 等线程 B。
// **未实测**（本机没有浏览器）：这是 worker-moonbit.mjs（已验证）的机械移植。

const SQL_OFF = 64;
const RES_OFF = 64 + 8192;
const decoder = new TextDecoder();
const encoder = new TextEncoder();
let ctrl = null;
let data = null;
let mem = null;
let pending = new Uint8Array(0);
let started = false;

function syncQuery(sql) {
  const bytes = encoder.encode(sql);
  const n = Math.min(bytes.length, 8192);
  data.set(bytes.subarray(0, n), SQL_OFF);
  Atomics.store(ctrl, 1, n);
  Atomics.store(ctrl, 0, 1);
  Atomics.notify(ctrl, 0);
  while (Atomics.load(ctrl, 0) !== 2) {
    Atomics.wait(ctrl, 0, 1, 1000);
  }
  const len = Atomics.load(ctrl, 2);
  pending = new Uint8Array(data.subarray(RES_OFF, RES_OFF + len));
  Atomics.store(ctrl, 0, 0);
  Atomics.notify(ctrl, 0);
  return 0;
}

async function start(wasmUrl) {
  const wasmBytes = await fetch(wasmUrl).then((r) => r.arrayBuffer());
  const imports = {
    mturso: {
      exec: (ptr, len) =>
        syncQuery(decoder.decode(new Uint8Array(mem.buffer, ptr, len))),
      result_len: () => pending.length,
      result_copy: (outPtr, cap) => {
        const n = Math.min(pending.length, cap);
        new Uint8Array(mem.buffer, outPtr, n).set(pending.subarray(0, n));
        return n;
      },
      log: (ptr, len) =>
        self.postMessage(decoder.decode(new Uint8Array(mem.buffer, ptr, len))),
    },
  };
  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  mem = instance.exports.memory;
  const t0 = performance.now();
  instance.exports.mt_demo();
  Atomics.store(ctrl, 3, 1);
  Atomics.notify(ctrl, 0);
  self.postMessage(`[worker A] mt_demo 返回，总耗时 ${Math.round(performance.now() - t0)}ms`);
}

self.onmessage = (e) => {
  if (started) {
    return;
  }
  started = true;
  ctrl = new Int32Array(e.data.sab, 0, 8);
  data = new Uint8Array(e.data.sab);
  start(e.data.wasm).catch((err) => self.postMessage("ERROR: " + err));
};
