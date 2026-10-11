# C ABI 最小骨架：每连接一个工作线程 + 门铃 pipe

用来回答两个问题：**C 侧要写多少代码？工作线程会不会卡住事件循环？**

## 结论（实测）

- 全部 **150 行**（含注释与空行），`gcc -Wall -Wextra` **零警告**；
- 运行输出里「心跳」连打 5 次 → 工作线程做阻塞查询时，**事件循环线程照常被调度**；
- 结果正确：`conn0 = 42 conn1 = 123`。

```
[心跳] 事件循环线程仍在跑别的任务 #1
...
结果：conn0 = 42 conn1 = 123
```

## 依赖

- **`turso.h`**：本机在 `/tmp/turso-src/sdk-kit/turso.h`（turso 源码 tag v0.8.2）；上游来源是
  `github.com/tursodatabase/turso` 的 `sdk-kit/turso.h`。
- **Turso C 库**：`libturso_sync_sdk_kit.so`（随 Go SDK 分发）。本机在
  `/home/jared/go/pkg/mod/github.com/tursodatabase/turso-go-platform-libs@v0.8.2/libs/linux_amd64/`。
  名字里带 `sync_sdk_kit` 有点误导——用 `nm -D --defined-only` 查过，它导出了 **77 个 `turso_*` C ABI 符号**
  （`turso_setup` / `turso_database_new` / `turso_statement_step` / `turso_statement_run_io` … 都在）。

## 编译运行

```bash
SO_DIR=/home/jared/go/pkg/mod/github.com/tursodatabase/turso-go-platform-libs@v0.8.2/libs/linux_amd64
gcc -O1 -Wall -Wextra -o /tmp/mini_worker mini_worker.c \
    -I/tmp/turso-src/sdk-kit -L"$SO_DIR" -lturso_sync_sdk_kit -lpthread
LD_LIBRARY_PATH="$SO_DIR" /tmp/mini_worker
```

注意 API 细节：`turso_database_connect` 的出参类型是**非 const** 的 `turso_connection_t **`
（用 `const turso_connection_t *` 接会报 incompatible pointer type），而 `*_deinit` 收 const。

## 设计要点（可直接照抄到 MoonBit 绑定）

1. **每连接一个线程，不做池**：连接与线程一一对应（actor），同一个连接永远只被一个线程碰 → 不需要
   pinning 逻辑、不需要共享 job 队列，也不需要把连接和 worker 绑定的额外簿记。连接数上来（上百）再考虑池。
2. **结果槽 + 互斥锁**：写结果要加锁；**先发布结果，再敲门铃**（顺序反了就会读到旧值）。
3. **门铃**：`pipe()`。MoonBit 侧把读端包成 `RawFdStream` 去 await（本示例用阻塞 `read()` 模拟；
   阻塞 fd 交给运行时后会自动走它内部线程池，所以事件循环线程不会被这个等待卡住）。
4. **`async_io = 0`**：库在**调用线程**上推进 I/O —— 这正是「工作线程必须由我们起」的原因（见
   `notes/turso-binding-guide.md` §6.3/§6.4）。
5. **一次通知可能对应多个完成**：真实实现里醒来要 drain 掉管道里所有字节，再检查**所有**连接的 pending 结果。
   本示例恰好按完成的字节数收，所以顺序无关。
6. **生命周期**：`*_deinit` 的前提是「之后没有任何代码再碰这个对象」（头文件 SAFETY 注释）；
   所以工作线程退出前要保证自己独占该连接。
