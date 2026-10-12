// spike 宿主：把 MoonBit 的 wasm 模块和真正的 Turso 接起来（Node 版）。
//
// 为什么要两趟跑：
//   Turso 的 JS API 只有异步版（prepare().all() / exec() 全是 Promise），
//   而 MoonBit 的 wasm 模块是同步的 —— 同步调用里没法 await。
//   所以这里用「先记录 SQL、再由宿主真正执行、再回放结果」的方式把这一趟跑通，
//   目的是验证两端的形状能不能对上（以及 ABI 对不对），不是最终架构。
//
//   最终形态见 README：MoonBit wasm 跑在 Web Worker 里，用 SharedArrayBuffer +
//   Atomics.wait 阻塞，另一个 worker 负责异步的 Turso 调用。

import fs from "node:fs";
import { connect } from "@tursodatabase/database";

const WASM = "moonbit/_build/wasm/debug/build/mturso-wasm-spike.wasm";
const wasmBytes = fs.readFileSync(WASM);
const decoder = new TextDecoder();

function makeImports(state, host) {
  // 注意：每次访问都重新取 memory.buffer —— wasm 内存可增长，老视图会失效。
  const readStr = (ptr, len) =>
    decoder.decode(new Uint8Array(state.mem.buffer, ptr, len));
  return {
    mturso: {
      exec: (ptr, len) => host.exec(readStr(ptr, len)),
      result_len: () => host.result_len(),
      result_copy: (outPtr, cap) => {
        const bytes = host.result_bytes();
        const n = Math.min(bytes.length, cap);
        new Uint8Array(state.mem.buffer, outPtr, n).set(bytes.subarray(0, n));
        return n;
      },
      log: (ptr, len) => console.log(readStr(ptr, len)),
    },
  };
}

async function runMoonBit(host) {
  const state = { mem: null };
  const { instance } = await WebAssembly.instantiate(
    wasmBytes,
    makeImports(state, host),
  );
  state.mem = instance.exports.memory;
  return instance.exports._start();
}

// ---- pass 1：记录 MoonBit 发出的 SQL -----------------------------------------
const script = [];
const recorder = {
  exec: (sql) => {
    if (sql.trim().length > 0) {
      script.push(sql);
    }
    return 0;
  },
  result_len: () => 0,
  result_bytes: () => new Uint8Array(0),
};
await runMoonBit(recorder);

// ---- 宿主真正执行这些 SQL（这里才是真 Turso）-------------------------------
const db = await connect(":memory:");
const results = [];
for (const sql of script) {
  const isQuery = /^\s*select/i.test(sql);
  if (isQuery) {
    const rows = await db.prepare(sql).all();
    results.push(JSON.stringify(rows));
  } else {
    await db.exec(sql);
    results.push("");
  }
}

console.log("--- MoonBit 发出的脚本 ---");
script.forEach((sql, i) => console.log(`  [${i}] ${sql}  =>  ${results[i] || "(no rows)"}`));

// ---- pass 2：把真实结果回放给 MoonBit ---------------------------------------
let cursor = 0;
const replayer = {
  exec: () => cursor++,
  result_len: () => Buffer.byteLength(results[cursor - 1] ?? "", "utf8"),
  result_bytes: () => Buffer.from(results[cursor - 1] ?? "", "utf8"),
};
console.log("--- MoonBit 侧看到的输出（数据来自真 Turso）---");
await runMoonBit(replayer);
