package main

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"

	"turso-go-sdk-example/mvccx"

	_ "turso.tech/database/tursogo"
)

// runConflict 演示 MVCC 的写写冲突：两个写事务改「同一条记录」时，后者**立即**报
// Write-write conflict 并被中止（first-committer-wins），而不是像 WAL 那样排队等待。
//
// 依据：core/mvcc/mod.rs 模块文档「prevent lost updates by detecting the write-write
// conflict and letting the first-writer win by aborting the later transaction」；
// core/mvcc/database/mod.rs 的 check_version_conflicts / check_rowid_for_conflicts
// 返回 LimboError::WriteWriteConflict（first-committer-wins）。
func runConflict() error {
	fmt.Println("\n### conflict：MVCC 写写冲突 —— 立即报错，而不是等待")

	ctx := context.Background()

	fmt.Println("\n  场景1：A 持有 id=1 未提交；B 写同一行")
	db, a, b, err := newMVCCDB()
	if err != nil {
		return err
	}
	defer db.Close()
	_, _ = a.ExecContext(ctx, `BEGIN CONCURRENT`)
	logStep("A", "update id=1", mustExec(a, `update t set v = 1 where id = 1`))
	_, _ = b.ExecContext(ctx, `BEGIN CONCURRENT`)
	logStep("B", "update id=1(同一行)", mustExec(b, `update t set v = 99 where id = 1`))
	logStep("B", "update id=2(另一行)", mustExec(b, `update t set v = 42 where id = 2`))
	fmt.Println("       ^ 冲突已让 B 的事务终止，这条其实是在 autocommit 下执行的")
	logStep("B", "COMMIT", mustExec(b, `COMMIT`))
	logStep("A", "COMMIT", mustExec(a, `COMMIT`))
	if err := dumpRows(db); err != nil {
		return err
	}

	fmt.Println("\n  场景2：B 先写 id=2（不冲突），再写 id=1（冲突）")
	db2, a2, b2, err := newMVCCDB()
	if err != nil {
		return err
	}
	defer db2.Close()
	_, _ = a2.ExecContext(ctx, `BEGIN CONCURRENT`)
	_ = mustExec(a2, `update t set v = 1 where id = 1`)
	_, _ = b2.ExecContext(ctx, `BEGIN CONCURRENT`)
	logStep("B", "update id=2(先，不冲突)", mustExec(b2, `update t set v = 42 where id = 2`))
	logStep("B", "update id=1(后，冲突)", mustExec(b2, `update t set v = 99 where id = 1`))
	logStep("B", "COMMIT", mustExec(b2, `COMMIT`))
	logStep("A", "COMMIT", mustExec(a2, `COMMIT`))
	if err := dumpRows(db2); err != nil {
		return err
	}
	fmt.Println("       ^ 注意 t[2] 仍是 0：冲突中止的是「整个事务」，先前的写也一起回滚了")

	fmt.Println("\n  场景3：A 先提交；B 的快照早于 A 的提交，再来写同一行")
	db3, a3, b3, err := newMVCCDB()
	if err != nil {
		return err
	}
	defer db3.Close()
	_, _ = a3.ExecContext(ctx, `BEGIN CONCURRENT`)
	_ = mustExec(a3, `update t set v = 1 where id = 1`)
	_, _ = b3.ExecContext(ctx, `BEGIN CONCURRENT`) // B 的快照早于 A 的提交
	logStep("A", "COMMIT(先)", mustExec(a3, `COMMIT`))
	logStep("B", "update id=1", mustExec(b3, `update t set v = 99 where id = 1`))
	_, _ = b3.ExecContext(ctx, `ROLLBACK`)

	fmt.Println("\n  场景4：同一个连接重试 —— 中止的是「事务」，不是「连接」")
	db4, a4, b4, err := newMVCCDB()
	if err != nil {
		return err
	}
	defer db4.Close()
	_, _ = a4.ExecContext(ctx, `BEGIN CONCURRENT`)
	_ = mustExec(a4, `update t set v = 1 where id = 1`)
	_, _ = b4.ExecContext(ctx, `BEGIN CONCURRENT`)
	logStep("B", "update id=1(冲突)", mustExec(b4, `update t set v = 100 where id = 1`))
	logStep("A", "COMMIT", mustExec(a4, `COMMIT`))
	logStep("B", "同连接 BEGIN CONCURRENT", mustExec(b4, `BEGIN CONCURRENT`))
	logStep("B", "同连接 update id=1", mustExec(b4, `update t set v = 100 where id = 1`))
	logStep("B", "同连接 COMMIT", mustExec(b4, `COMMIT`))
	if err := dumpRows(db4); err != nil {
		return err
	}
	fmt.Println("       ^ 同一个连接重试完全可行 —— 前提是必须「重新 BEGIN」")

	fmt.Println("\n  场景5：同一个连接，但重试时「忘了 BEGIN」")
	db5, a5, b5, err := newMVCCDB()
	if err != nil {
		return err
	}
	defer db5.Close()
	_, _ = a5.ExecContext(ctx, `BEGIN CONCURRENT`)
	_ = mustExec(a5, `update t set v = 1 where id = 1`)
	_, _ = b5.ExecContext(ctx, `BEGIN CONCURRENT`)
	logStep("B", "update id=1(冲突)", mustExec(b5, `update t set v = 100 where id = 1`))
	logStep("B", "重试① id=2（无 BEGIN）", mustExec(b5, `update t set v = 7 where id = 2`))
	logStep("B", "重试② insert id=1", mustExec(b5, `insert into t(id, v) values (1, 999)`))
	_ = mustExec(a5, `COMMIT`)
	if err := dumpRows(db5); err != nil {
		return err
	}
	fmt.Println("       ^ 重试① 已在 autocommit 下提交，重试② 失败也撤不回它 = 半截写入")

	fmt.Println("\n  场景6：正确的失败处理 —— 冲突就重试整个事务（只错在场景5没做处理）")
	db6, a6, _, err := newMVCCDB()
	if err != nil {
		return err
	}
	defer db6.Close()
	_ = mustExec(a6, `update t set v = 0 where id = 1`)
	_ = a6.Close()

	const workers, incs = 2, 20
	var (
		wg       sync.WaitGroup
		attempts atomic.Int64
		failures atomic.Int64
	)
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := db6.Conn(ctx)
			if err != nil {
				failures.Add(1)
				return
			}
			defer conn.Close()
			for i := 0; i < incs; i++ {
				// 用 mvccx.Run 把「失败处理」交给封装：可重试错误自动重跑整个事务。
				err := mvccx.Run(ctx, conn, mvccx.Options{Attempts: 500}, func(ctx context.Context, tx *mvccx.Tx) error {
					attempts.Add(1)
					_, err := tx.ExecContext(ctx, `update t set v = v + 1 where id = 1`)
					return err
				})
				if err != nil {
					failures.Add(1)
					return
				}
			}
		}()
	}
	wg.Wait()

	var v int
	if err := db6.QueryRow(`select v from t where id = 1`).Scan(&v); err != nil {
		return err
	}
	fmt.Printf("    %d 个并发写者 × %d 次自增：最终 v = %d（期望 %d），事务尝试 %d 次（重试 %d 次），失败 %d 次\n",
		workers, incs, v, workers*incs, attempts.Load(), attempts.Load()-workers*incs, failures.Load())
	fmt.Println("       ^ mvccx.Run 内建重试：同一连接反复用，结果正确、无丢失更新")

	fmt.Println("\n  结论：")
	fmt.Println("    · 冲突在「写那条记录」的语句上立即返回，不等待（对比 WAL：会等到写锁释放或超时）")
	fmt.Println("    · 中止的是「事务」不是「连接」：同一个连接重新 BEGIN CONCURRENT 就能重试成功")
	fmt.Println("    · 冲突后连接会静默回到 autocommit：这是「客户端没做失败处理」才会踩的坑（场景5）")
	fmt.Println("    · 正确写法（场景6）：用 mvccx.Run —— 冲突自动重跑整个事务，回调里的 Tx 已带 done 保护")
	fmt.Println("    · 检测是行级的：改不同的行互不影响（这才是 MVCC 的并发收益）")
	fmt.Println("    · 注意 database/sql 的 db.BeginTx 发的是普通 BEGIN，在 Turso 下拿不到 MVCC 并发写语义")
	fmt.Println("      （binding 的 BeginTx 直接忽略了 driver.TxOptions，所以只能自己封装，见 mvccx 包）")
	return nil
}

// newMVCCDB 建一个 mvcc 模式的临时库，表 t 有两行。
func newMVCCDB() (*sql.DB, *sql.Conn, *sql.Conn, error) {
	dir, cleanup, err := tempDir()
	if err != nil {
		return nil, nil, nil, err
	}
	_ = cleanup // 数据留在临时目录里便于观察
	path := filepath.Join(dir, "conflict.db")

	setup, err := sql.Open("turso", path)
	if err != nil {
		return nil, nil, nil, err
	}
	var mode string
	if err := setup.QueryRow(`PRAGMA journal_mode='mvcc'`).Scan(&mode); err != nil {
		return nil, nil, nil, err
	}
	if _, err := setup.Exec(`create table t(id integer primary key, v integer)`); err != nil {
		return nil, nil, nil, err
	}
	if _, err := setup.Exec(`insert into t values (1, 0), (2, 0)`); err != nil {
		return nil, nil, nil, err
	}
	_ = setup.Close()

	ctx := context.Background()
	db, err := sql.Open("turso", path)
	if err != nil {
		return nil, nil, nil, err
	}
	a, err := db.Conn(ctx)
	if err != nil {
		return nil, nil, nil, err
	}
	b, err := db.Conn(ctx)
	if err != nil {
		return nil, nil, nil, err
	}
	return db, a, b, nil
}

func mustExec(c *sql.Conn, sqlText string) error {
	_, err := c.ExecContext(context.Background(), sqlText)
	return err
}

func logStep(who, what string, err error) {
	if err == nil {
		fmt.Printf("    %s %-24s -> ok\n", who, what)
		return
	}
	fmt.Printf("    %s %-24s -> %v\n", who, what, err)
}

func dumpRows(db *sql.DB) error {
	rows, err := db.Query(`select id, v from t order by id`)
	if err != nil {
		return err
	}
	defer rows.Close()
	fmt.Print("      最终值: ")
	for rows.Next() {
		var id, v int
		if err := rows.Scan(&id, &v); err != nil {
			return err
		}
		fmt.Printf("t[%d]=%d ", id, v)
	}
	fmt.Println()
	return rows.Err()
}
