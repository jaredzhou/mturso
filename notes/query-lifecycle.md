# mturso 查询生命周期

本文描述一次 `Connection::query(sql, params)` 从连接创建到结果释放的完整路径。

```mermaid
sequenceDiagram
    autonumber
    actor App as MoonBit 调用方
    participant DB as Database / 连接池
    participant Conn as Connection
    participant Worker as C worker 线程
    participant Turso as Turso Engine
    participant Pipe as 结果管道
    participant Rows as ResultRows

    Note over DB,Turso: 数据库初始化，通常只执行一次
    App->>DB: Database::open(path)
    DB->>Turso: LoadLibraryA / dlopen
    DB->>Turso: turso_setup
    DB->>Turso: database_new + database_open
    Turso-->>DB: raw database handle
    DB-->>App: Database（含 semaphore）

    App->>DB: db.connect()
    DB->>DB: semaphore.acquire()
    alt 有空闲连接
        DB->>DB: 从 idle 复用 raw connection
    else 需要新连接
        DB->>Turso: database_connect
        Turso-->>DB: raw connection
        DB->>Worker: 创建 worker thread + mutex + condvar
    end
    DB-->>App: Connection checkout

    App->>Conn: query(sql, params)
    Conn->>Turso: prepare_first(sql)
    Turso-->>Conn: stmt + tail offset

    alt prepare 失败
        Conn-->>App: raise QueryError / Busy / Conflict
    else prepare 成功
        Conn->>Conn: 检查只能有一条 SQL
        Conn->>Turso: bind ?1、?2……
        Conn->>Pipe: 创建管道 read / write
        Conn->>Worker: submit_job(stmt, write_end)
        Note over Conn,Worker: 一个 Connection 同时只允许一个 stream job

        par Worker 异步生产
            Worker->>Turso: step / run_io 循环
            Worker->>Pipe: 写 HEADER 帧
            loop 每一行
                Worker->>Turso: step
                Turso-->>Worker: TURSO_ROW
                Worker->>Pipe: 写 ROW 帧
            end
            Worker->>Turso: step
            Turso-->>Worker: TURSO_DONE
            Worker->>Pipe: 写 END 帧（affected rows）
            Worker->>Pipe: 关闭 write_end
            Worker->>Worker: busy = false，广播 condvar
        and MoonBit 异步消费
            Conn->>Pipe: RawFdStream(read_end)
            Conn->>Pipe: read_exactly(HEADER)
            Pipe-->>Conn: 列名与声明类型
            Conn-->>App: ResultRows
            loop 直到 END 或 ERROR
                App->>Rows: has_next()
                Rows->>Pipe: read_exactly(5 字节帧头)
                Rows->>Pipe: read_exactly(payload 长度)
                Pipe-->>Rows: ROW / END / ERROR

                alt ROW
                    Rows-->>App: true
                    App->>Rows: get_row()
                    Rows-->>App: Row(values, raw bytes)
                else END
                    Rows-->>App: false
                else ERROR
                    Rows-->>App: raise TursoError
                end
            end
        end
    end

    Note over Worker,Pipe: 管道有界。MoonBit 读得慢时，Worker 写满管道会阻塞，形成背压

    App->>Rows: rows.close()
    Rows->>Pipe: 关闭 read_end
    alt 查询尚未读完
        Worker->>Pipe: 后续写入失败
        Note over Worker: Unix 得到 EPIPE<br/>Windows 得到 ERROR_BROKEN_PIPE
        Worker->>Worker: 停止当前 job
    end
    Rows->>Worker: conn_wait_job()
    Worker-->>Rows: 当前 job 已结束
    Note over Rows: 此时 stmt 可以安全释放

    opt 查询由 db.query / db.begin_tx 借用
        Rows->>DB: connection.close()
        DB->>DB: 放回 idle，semaphore.release()
    end

    opt 显式关闭 Database
        App->>DB: db.close()
        DB->>Worker: 对所有连接 shutdown + join
        DB->>Turso: connection_deinit
        DB->>Turso: database_deinit
    end
```

## 读图重点

- `fds[0]` 是管道读端，交给 MoonBit 的 `RawFdStream`；`fds[1]` 是写端，只交给 C worker。
- `query()` 返回时通常只消费了 `HEADER`。后续行通过 `rows.has_next()` 和 `rows.get_row()` 从管道继续拉取。
- worker 在独立线程中执行 Turso 的 `step` / `run_io`，不会阻塞 MoonBit 事件循环。
- 管道是有界 FIFO。结果生产得太快时，worker 会在写入端阻塞，从而限制未消费结果占用的内存。
- `rows.close()` 先关闭读端，再等待 worker 结束；这样 `stmt` 在执行线程停止后才能安全释放。
- 池化查询结束后，`Connection::close()` 将连接放回 `Database` 的 idle 列表，不销毁 worker 线程。

## 源码入口

- 连接池与 worker 生命周期：[`ffi/connection.c`](../ffi/connection.c)
- 管道创建与 job 提交：[`ffi/statement.c`](../ffi/statement.c)
- 结果帧写入：[`ffi/stream.c`](../ffi/stream.c)
- POSIX / Win32 句柄与同步抽象：[`ffi/platform.h`](../ffi/platform.h)
- `query()` 与帧读取：[`rows.mbt`](../rows.mbt)
- `Database::open` / `connect`：[`mturso.mbt`](../mturso.mbt)
