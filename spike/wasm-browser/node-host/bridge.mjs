import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Worker as NodeWorker } from "node:worker_threads";

const hostDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(hostDir, "..");
const moonbitWasm = resolve(
  root,
  "moonbit/_build/wasm/release/build/mturso-wasm-spike.wasm",
);
const tursoPackage = import.meta.resolve("@tursodatabase/database-wasm");
const tursoWorkerShim = new URL("./turso-worker-shim.mjs", import.meta.url);
const moonbitWorker = new URL("./moonbit-worker.mjs", import.meta.url);
const startedAt = performance.now();

class BrowserWorker extends NodeWorker {
  #listeners = new Map();

  constructor(url, options = {}) {
    const target = String(url).endsWith("/worker.js")
      ? tursoWorkerShim
      : url;
    super(target, { name: options.name });
  }

  addEventListener(type, callback) {
    if (type !== "message") {
      return;
    }
    const listener = data => callback({ data });
    this.#listeners.set(callback, listener);
    this.on("message", listener);
  }

  removeEventListener(_type, callback) {
    const listener = this.#listeners.get(callback);
    if (listener) {
      this.off("message", listener);
      this.#listeners.delete(callback);
    }
  }
}

globalThis.Worker = BrowserWorker;

const NativeMemory = WebAssembly.Memory;
const wasmMemories = [];
WebAssembly.Memory = new Proxy(NativeMemory, {
  construct(target, args) {
    const memory = Reflect.construct(target, args);
    wasmMemories.push(memory);
    return memory;
  },
});

const originalFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = new URL(input);
  if (url.protocol === "file:") {
    return new Response(await readFile(url), init);
  }
  return originalFetch(input, init);
};

const { connect } = await import(tursoPackage);
const db = await connect(":memory:");

const shared = new SharedArrayBuffer(3 * Int32Array.BYTES_PER_ELEMENT + 1_048_576);
const control = new Int32Array(shared, 0, 3);
const payload = new Uint8Array(shared, 3 * Int32Array.BYTES_PER_ELEMENT);
const encoder = new TextEncoder();

const worker = new NodeWorker(moonbitWorker, {
  workerData: { wasmPath: moonbitWasm, shared },
});
let moonbitMemoryBytes = 0;

worker.on("message", async message => {
  if (message.type === "ready") {
    moonbitMemoryBytes = message.memoryBytes;
    return;
  }
  if (message.type !== "exec") {
    return;
  }

  let status = 0;
  let result = "";
  try {
    if (/^\s*select\b/i.test(message.sql)) {
      const rows = await db.prepare(message.sql).all();
      result = rows
        .map(row => Object.values(row).map(formatCell).join("\t"))
        .join("\n");
    } else {
      await db.exec(message.sql);
    }
  } catch (error) {
    status = 1;
    result = error instanceof Error ? error.message : String(error);
    console.error(`Turso wasm host error: ${result}`);
  }

  const bytes = encoder.encode(result);
  if (bytes.length > payload.length) {
    status = 1;
    result = `result too large: ${bytes.length} > ${payload.length}`;
    console.error(result);
  } else {
    payload.set(bytes);
  }
  Atomics.store(control, 2, Math.min(bytes.length, payload.length));
  Atomics.store(control, 1, status);
  Atomics.store(control, 0, 1);
  Atomics.notify(control, 0);
});

const exitCode = await new Promise((resolveExit, reject) => {
  worker.once("error", reject);
  worker.once("exit", resolveExit);
});

await db.close();
if (exitCode !== 0) {
  throw new Error(`MoonBit wasm worker exited with ${exitCode}`);
}
const tursoMemoryBytes = Math.max(
  0,
  ...wasmMemories.map(memory => memory.buffer.byteLength),
);
console.error(
  [
    `metrics: elapsed_ms=${(performance.now() - startedAt).toFixed(1)}`,
    `turso_wasm_memory_bytes=${tursoMemoryBytes}`,
    `moonbit_wasm_memory_bytes=${moonbitMemoryBytes}`,
    `rss_bytes=${process.memoryUsage().rss}`,
  ].join(" "),
);

function formatCell(value) {
  if (value === null) {
    return "NULL";
  }
  if (value instanceof Uint8Array) {
    return `<blob:${value.length}>`;
  }
  return String(value);
}
