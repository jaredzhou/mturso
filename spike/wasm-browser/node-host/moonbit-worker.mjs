import { readFile } from "node:fs/promises";
import { parentPort, workerData } from "node:worker_threads";

const module = await WebAssembly.compile(await readFile(workerData.wasmPath));
const control = new Int32Array(workerData.shared, 0, 3);
const payload = new Uint8Array(
  workerData.shared,
  3 * Int32Array.BYTES_PER_ELEMENT,
);
const decoder = new TextDecoder();
let memory;

const imports = {
  wasi_snapshot_preview1: {
    fd_write(fd, iovsPtr, iovsLen, writtenPtr) {
      let written = 0;
      const view = new DataView(memory.buffer);
      for (let i = 0; i < iovsLen; i++) {
        const base = iovsPtr + i * 8;
        const ptr = view.getUint32(base, true);
        const len = view.getUint32(base + 4, true);
        const chunk = new Uint8Array(memory.buffer, ptr, len);
        if (fd === 1) {
          process.stdout.write(chunk);
        } else {
          process.stderr.write(chunk);
        }
        written += len;
      }
      view.setUint32(writtenPtr, written, true);
      return 0;
    },
  },
  mturso: {
    exec(sqlPtr, sqlLen) {
      const sql = decoder.decode(
        new Uint8Array(memory.buffer, sqlPtr, sqlLen),
      );
      Atomics.store(control, 0, 0);
      parentPort.postMessage({ type: "exec", sql });
      return Atomics.wait(control, 0, 0, 30_000) === "ok"
        ? Atomics.load(control, 1)
        : 1;
    },
    result_len() {
      return Atomics.load(control, 2);
    },
    result_copy(outPtr, cap) {
      const len = Math.min(cap, Atomics.load(control, 2));
      new Uint8Array(memory.buffer, outPtr, len).set(payload.subarray(0, len));
      return len;
    },
    log(msgPtr, msgLen) {
      console.log(decoder.decode(new Uint8Array(memory.buffer, msgPtr, msgLen)));
    },
  },
};

const instance = await WebAssembly.instantiate(module, imports);
memory = instance.exports.memory;
parentPort.postMessage({
  type: "ready",
  memoryBytes: memory.buffer.byteLength,
});
instance.exports._start();
