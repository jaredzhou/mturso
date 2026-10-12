// 浏览器版线程 B：Turso 的浏览器包（wasm + 它自己的内部 worker）。**未实测**。
// 用相对路径直接引 bundle，避免浏览器里没有 bare specifier 解析。

import { connect } from "../node_modules/@tursodatabase/database-wasm/bundle/main.es.js";

let ctrl = null;
let data = null;
const SQL_OFF = 64;
const RES_OFF = 64 + 8192;
const RES_CAP = 65536;
const decoder = new TextDecoder();
const encoder = new TextEncoder();
let db = null;

async function produce(sql) {
  const isQuery = /^\s*(select|pragma|with)/i.test(sql);
  if (!isQuery) {
    await db.exec(sql);
    return "";
  }
  const rows = await db.prepare(sql).all();
  return rows.map((r) => Object.values(r).join("\t")).join("\n");
}

async function loop() {
  db = await connect(":memory:");
  for (;;) {
    while (Atomics.load(ctrl, 0) !== 1) {
      if (Atomics.load(ctrl, 3) === 1) {
        self.postMessage("timed out");
        return;
      }
      Atomics.wait(ctrl, 0, 0, 200);
    }
    const sql = decoder.decode(data.subarray(SQL_OFF, SQL_OFF + Atomics.load(ctrl, 1)));
    try {
      const bytes = encoder.encode(await produce(sql));
      const n = Math.min(bytes.length, RES_CAP);
      data.set(bytes.subarray(0, n), RES_OFF);
      Atomics.store(ctrl, 2, n);
    } catch (err) {
      self.postMessage("turso error: " + err);
      Atomics.store(ctrl, 2, 0);
    }
    Atomics.store(ctrl, 0, 2);
    Atomics.notify(ctrl, 0);
  }
}

self.onmessage = (e) => {
  ctrl = new Int32Array(e.data.sab, 0, 8);
  data = new Uint8Array(e.data.sab);
  loop().catch((err) => self.postMessage("ERROR: " + err));
};
