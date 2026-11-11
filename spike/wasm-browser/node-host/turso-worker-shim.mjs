import { parentPort } from "node:worker_threads";

// The Turso wasm package targets browser Workers. Node 22 exposes WebAssembly
// and SharedArrayBuffer but not the browser Worker globals, so bridge those
// globals onto worker_threads while importing Turso's stock worker entry.
globalThis.self = globalThis;
globalThis.postMessage = message => parentPort.postMessage(message);

parentPort.on("message", data => {
  if (globalThis.onmessage) {
    globalThis.onmessage({ data });
  }
});

const workerEntry = new URL(
  "./worker.js",
  import.meta.resolve("@tursodatabase/database-wasm"),
);
await import(workerEntry.href);
