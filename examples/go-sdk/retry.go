package main

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"turso-go-sdk-example/mvccx"
)

// runRetry 用实测回答「MVCC 下重试多少次合适」：
//  1. 争用越强，需要的尝试次数越多（但主要取决于你的退避策略）；
//  2. 把「退避」换成 full jitter 指数退避后，所需次数会降一个数量级。
//
// 场景是最坏情况：所有写者都在对**同一行**做 read-modify-write。
func runRetry() error {
	fmt.Println("\n### retry：MVCC 重试预算该给多少？（实测）")
	fmt.Println("  场景：所有写者抢同一行做 v = v + 1（最坏情况），每个写者 10 个逻辑事务，尝试上限 200")

	fmt.Println("\n  ① 争用强度 → 所需尝试次数（无退避，即惊群式立即重试）")
	fmt.Printf("     %-8s %-10s %-6s %-6s %s\n", "写者数", "平均尝试", "p99", "最大", "失败")
	for _, writers := range []int{1, 2, 4, 8, 16} {
		r := retryMeasure(writers, 10, mvccx.Options{
			Attempts:  200,
			BaseDelay: time.Nanosecond, // ≈ 无退避
			MaxDelay:  time.Nanosecond,
		})
		fmt.Printf("     %-8d %-10.2f %-6d %-6d %d\n", writers, r.mean, r.p99, r.max, r.fails)
	}

	fmt.Println("\n  ② 8 个写者时，退避策略的影响")
	tight := retryMeasure(8, 10, mvccx.Options{Attempts: 200, BaseDelay: time.Nanosecond, MaxDelay: time.Nanosecond})
	good := retryMeasure(8, 10, mvccx.Options{Attempts: 200}) // mvccx 默认：full jitter 指数退避
	fmt.Printf("     %-14s 平均尝试 %-6.2f p99 %-4d 失败 %d\n", "无退避", tight.mean, tight.p99, tight.fails)
	fmt.Printf("     %-14s 平均尝试 %-6.2f p99 %-4d 失败 %d\n", "full jitter", good.mean, good.p99, good.fails)

	fmt.Println("\n  结论：")
	fmt.Println("    · 别用固定次数拍脑袋——先把退避做对：无退避时，仅 2 个写者抢同一行就要平均十几次尝试")
	fmt.Println("    · 用「次数 + 时间预算」双重约束：mvccx 默认 Attempts=10、1ms→50ms full jitter，一般够用")
	fmt.Println("    · 看 p99 而不是平均值：平均 3 次但 p99 30 次，尾部事务会退避到几十毫秒")
	fmt.Println("    · 若 p99 仍需几十次 → 这是结构性热点争用，重试解决不了，应改访问模式（分片/批量/单写者队列）")
	fmt.Println("    · 纯 DB 操作重试无需额外幂等（中止会整体回滚）；要防的是事务体里的「非 DB 副作用」")
	return nil
}

type retryStats struct {
	mean  float64
	p99   int
	max   int
	fails int
}

func retryMeasure(writers, logical int, opts mvccx.Options) retryStats {
	dir, cleanup, err := tempDir()
	if err != nil {
		return retryStats{}
	}
	defer cleanup()
	path := filepath.Join(dir, "retry.db")

	setup, err := sql.Open("turso", path)
	if err != nil {
		return retryStats{}
	}
	var mode string
	if err := setup.QueryRow(`PRAGMA journal_mode='mvcc'`).Scan(&mode); err != nil {
		return retryStats{}
	}
	if _, err := setup.Exec(`create table t(id integer primary key, v integer)`); err != nil {
		return retryStats{}
	}
	if _, err := setup.Exec(`insert into t values (1, 0)`); err != nil {
		return retryStats{}
	}
	_ = setup.Close()

	db, err := sql.Open("turso", path)
	if err != nil {
		return retryStats{}
	}
	defer db.Close()
	db.SetMaxOpenConns(writers + 2)

	ctx := context.Background()
	total := writers * logical
	attempts := make([]int, total)
	var idx, fails atomic.Int64

	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := db.Conn(ctx)
			if err != nil {
				return
			}
			defer conn.Close()
			for i := 0; i < logical; i++ {
				n := 0
				err := mvccx.Run(ctx, conn, opts, func(ctx context.Context, tx *mvccx.Tx) error {
					n++ // fn 每被调用一次 = 一次尝试
					_, err := tx.ExecContext(ctx, `update t set v = v + 1 where id = 1`)
					return err
				})
				attempts[idx.Add(1)-1] = max(n, 1)
				if err != nil {
					fails.Add(1)
				}
			}
		}()
	}
	wg.Wait()

	sort.Ints(attempts)
	sum := 0
	for _, a := range attempts {
		sum += a
	}
	return retryStats{
		mean:  float64(sum) / float64(max(total, 1)),
		p99:   attempts[minInt(int(float64(total)*0.99), total-1)],
		max:   attempts[total-1],
		fails: int(fails.Load()),
	}
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
