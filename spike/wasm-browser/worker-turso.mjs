// 线程 B：真正的 Turso（异步 API 在**这个**线程上跑，所以它的 event loop 不被阻塞）。
//
// 与线程 A 通过 SharedArrayBuffer 同步：
//   ctrl[0]  0 = 空闲（B 等请求） / 1 = A 已发请求（B 干活） / 2 = B 已写好结果（A 可以取）
//   ctrl[1]  SQL 字节数
//   ctrl[2]  结果字节数
//   ctrl[3]  A 结束标志

import { workerData } from "node:worker_threads";
import { connect } from "@tursodatabase/database";

const ctrl = new Int32Array(workerData.sab, 0, 8);
const data = new Uint8Array(workerData.sab);
const SQL_OFF = 64;
const RES_OFF = 64 + 8192;
const RES_CAP = 65536;

const decoder = new TextDecoder();
const encoder = new TextEncoder();
const db = await connect(":memory:");

/// 把结果写成和 native 绑定一样的「行内制表符、行间换行」文本。
async function produce(sql) {
  const isQuery = /^\s*(select|pragma|with)/i.test(sql);
  if (!isQuery) {
    await db.exec(sql);
    return "";
  }
  const rows = await db.prepare(sql).all();
  return rows.map((r) => Object.values(r).join("\t")).join("\n");
}

for (;;) {
  // 等线程 A 发请求（state 停在 1 时阻塞；A 发请求时会把它置 1 并 notify）
  while (Atomics.load(ctrl, 0) !== 1) {
    if (Atomics.load(ctrl, 3) === 1) {
      process.exit(0);
    }
    Atomics.wait(ctrl, 0, 0, 200);
  }
  const sql = decoder.decode(data.subarray(SQL_OFF, SQL_OFF + Atomics.load(ctrl, 1)));
  const text = await produce(sql);
  const bytes = encoder.encode(text);
  const n = Math.min(bytes.length, RES_CAP);
  data.set(bytes.subarray(0, n), RES_OFF);
  Atomics.store(ctrl, 2, n);
  Atomics.store(ctrl, 0, 2);
  Atomics.notify(ctrl, 0);
}
