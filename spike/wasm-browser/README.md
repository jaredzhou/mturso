# mturso WASM spike

This is the runnable proof for ticket #10. MoonBit compiles to the linear-memory
`wasm` target and runs in a Node Worker. The host drives
`@tursodatabase/database-wasm@0.8.2`, also compiled as WebAssembly.

```bash
npm install
npm run run
```

Expected output:

```text
=== mturso wasm spike ===
1	alice
2	bob
42
```

Chain:

```text
MoonBit wasm Worker
  query(sql)
    -> imported mturso.exec
       -> SharedArrayBuffer request + Atomics.wait
          -> Node host
             -> @tursodatabase/database-wasm
                -> turso.wasm32-wasi.wasm
          <- result bytes + Atomics.notify
    <- result_copy
  <- String
```

The MoonBit Worker blocks on `Atomics.wait`; the host thread remains free to
drive Turso's Promise-based API. This is why the synchronous demo does not
deadlock the JS event loop.

This is a spike, not the final API:

- memory database, one logical connection, synchronous host ABI
- one serialized request per wasm instance
- query results are materialized by the JS wrapper before copying to MoonBit
- a 1 MiB shared result buffer
- Node host only; browser execution still needs COOP/COEP headers and a browser
  worker topology

See [`notes/wasm-spike.md`](../../notes/wasm-spike.md) for findings, tradeoffs,
measurements, and the recommended implementation slices.
