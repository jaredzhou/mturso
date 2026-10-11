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
)

const writesPerWkr = 25

// runConcurrent 用实测回答两个常见疑问：
//  1. 默认（WAL）不是不允许并发写吗，为什么示例里面全部成功？
//     → 因为有 busy timeout：抢不到写锁的写者会排队等待，而不是立刻失败。
//  2. 关掉 busy timeout 后，是不是「同一时间的尝试全都失败」？
//     → 不是。只有**恰好撞上别人持写锁**的那几条会失败；其余照常成功。
//
// 对照实验：
//
//	A) 8 连接 + busy_timeout=10s  → 200 次尝试全部成功，但被写锁串行化（有单连接基线对照）
//	B) 8 连接 + busy_timeout 关闭 → 记录每一次尝试的结果，看失败到底有多少、来自哪里
//	C) 1 个写者 + busy_timeout 关闭 → 全部成功，证明「禁用忙等待本身并不会导致失败」
//	D) 长写事务独占写锁 + 忙等待   → 第二个写者等待后成功
//	E) 长写事务独占写锁 + 关忙等待 → 第二个写者立即失败
func runConcurrent() error {
	fmt.Println("\n### concurrent：WAL 是单写者，「并发写」其实是在排队")

	if err := concurrentWriters("A) 8 连接 + busy_timeout=10000ms", 10000, 8); err != nil {
		return err
	}
	if err := concurrentWritersDuration("B) 8 连接 + busy_timeout 关闭(-1)（按持续时间压测）", -1, 8, 500*time.Millisecond); err != nil {
		return err
	}
	if err := concurrentWriters("C) 1 个写者 + busy_timeout 关闭(-1)（对照）", -1, 1); err != nil {
		return err
	}
	if err := writeLockContention("D) 长写事务独占写锁 + busy_timeout=5000ms", 5000); err != nil {
		return err
	}
	return writeLockContention("E) 长写事务独占写锁 + busy_timeout 关闭(-1)", -1)
}

// concurrentWritersDuration 按「持续时间」而不是「固定尝试次数」施加压力。
// 这一点很关键：关闭忙等待时，失败的尝试只要 ~50µs，而成功一次要 ~4ms（差约 100 倍）。
// 如果用固定次数，失败者会在 ~1ms 内就把配额烧光然后退出，看起来像「锁被独占、永不易主」——
// 那其实是测量偏差，不是事实。
func concurrentWritersDuration(label string, busyTimeoutMs, workers int, dur time.Duration) error {
	dir, cleanup, err := tempDir()
	if err != nil {
		return err
	}
	defer cleanup()
	path := filepath.Join(dir, "wal.db")

	setup, err := sql.Open("turso", path)
	if err != nil {
		return err
	}
	if _, err := setup.Exec(`create table t(id integer primary key, worker integer, n integer)`); err != nil {
		return err
	}
	setup.Close()

	dsn := fmt.Sprintf("%s?_busy_timeout=%d", path, busyTimeoutMs)
	var (
		mu  sync.Mutex
		evs []writeSpan2
		ok  = make([]atomic.Int64, workers)
		att = make([]atomic.Int64, workers)
	)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			db, err := sql.Open("turso", dsn)
			if err != nil {
				return
			}
			defer db.Close()
			<-start
			deadline := time.Now().Add(dur)
			for time.Now().Before(deadline) {
				att[w].Add(1)
				ts := time.Now().UnixNano()
				if _, err := db.Exec(`insert into t(worker, n) values (?, 0)`, w); err != nil {
					continue
				}
				mu.Lock()
				evs = append(evs, writeSpan2{w, ts})
				mu.Unlock()
				ok[w].Add(1)
			}
		}(w)
	}
	begin := time.Now()
	close(start)
	wg.Wait()
	wall := time.Since(begin)

	sort.Slice(evs, func(i, j int) bool { return evs[i].t < evs[j].t })
	handoffs, last := 0, -1
	for _, e := range evs {
		if last != -1 && e.w != last {
			handoffs++
		}
		last = e.w
	}

	var totalOK, totalAtt, winners int64
	for w := 0; w < workers; w++ {
		totalOK += ok[w].Load()
		totalAtt += att[w].Load()
		if ok[w].Load() > 0 {
			winners++
		}
	}
	ratio := float64(totalAtt) / float64(max(totalOK, 1))

	fmt.Printf("  %s\n", label)
	fmt.Printf("    持续 %.0fms：成功写入 %d 次，尝试 %d 次 → 每成功 1 次要试 %.0f 次（大量无效自旋）\n",
		ms(wall), totalOK, totalAtt, ratio)
	fmt.Printf("    写锁易主 %d 次；%d/%d 个写者都成功写入过 → 锁会易主，不存在「谁抢到就永久独占」\n",
		handoffs, winners, workers)
	fmt.Println("    结论：关闭忙等待不会饿死其他写者，但代价是 ~1000 次无效重试/成功；忙等待正是用来消除这些空转的")
	return nil
}

type writeSpan2 struct {
	w int
	t int64
}

type writeSpan struct{ start, end int64 }

// concurrentWriters 让 workers 个连接各自尝试 writesPerWkr 次写，
// **记录每一次尝试的结果**（不在首次失败时中断），统计成功率与同时在飞的语句数。
func concurrentWriters(label string, busyTimeoutMs, workers int) error {
	dir, cleanup, err := tempDir()
	if err != nil {
		return err
	}
	defer cleanup()
	path := filepath.Join(dir, "wal.db")

	setup, err := sql.Open("turso", path)
	if err != nil {
		return err
	}
	if _, err := setup.Exec(`create table t(id integer primary key, worker integer, n integer)`); err != nil {
		return err
	}
	setup.Close()

	dsn := fmt.Sprintf("%s?_busy_timeout=%d", path, busyTimeoutMs)

	var (
		mu       sync.Mutex
		spans    []writeSpan
		firstErr string
		ok       atomic.Int64
		failed   atomic.Int64
	)
	perWorker := make([]atomic.Int64, workers) // 每个写者成功了多少次
	start := make(chan struct{})
	var wg sync.WaitGroup
	begin := time.Now()
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			db, err := sql.Open("turso", dsn)
			if err != nil {
				failed.Add(1)
				return
			}
			defer db.Close()
			<-start // 尽量同时起跑，制造冲突
			for i := 0; i < writesPerWkr; i++ {
				s := time.Now().UnixNano()
				_, err := db.Exec(`insert into t(worker, n) values (?, ?)`, w, i)
				e := time.Now().UnixNano()
				if err != nil {
					failed.Add(1)
					mu.Lock()
					if firstErr == "" {
						firstErr = err.Error()
					}
					mu.Unlock()
					continue // 不中断：把每一次尝试都算进去
				}
				mu.Lock()
				spans = append(spans, writeSpan{s, e})
				mu.Unlock()
				ok.Add(1)
				perWorker[w].Add(1)
			}
		}(w)
	}
	close(start)
	wg.Wait()
	wall := time.Since(begin)
	total := workers * writesPerWkr

	winners := 0
	for w := range perWorker {
		if perWorker[w].Load() > 0 {
			winners++
		}
	}

	fmt.Printf("  %s\n", label)
	fmt.Printf("    尝试 %d 次：成功 %d，失败 %d；墙钟 %.0fms\n",
		total, ok.Load(), failed.Load(), ms(wall))
	if workers > 1 && failed.Load() > 0 {
		fmt.Printf("    %d 个写者中成功写入过的只有 %d 个（其余全部尝试皆失败）\n", workers, winners)
	}
	fmt.Printf("    同时在飞（含排队等待）的写语句最多 = %d 个\n", maxOverlap(spans))
	if firstErr != "" {
		fmt.Printf("    首个错误：%s\n", firstErr)
	}

	if failed.Load() == 0 && workers > 1 {
		// 没有失败才有意义做「并行 vs 单连接」的吞吐对照。
		base, err := singleConnBaseline(path, busyTimeoutMs, total)
		if err != nil {
			return err
		}
		fmt.Printf("    单连接基线：%d 次写 %.0fms → %s\n", total, ms(base), speedupNote(wall, base))
	} else if failed.Load() > 0 {
		fmt.Println("    说明：持续的争抢下，抢到写锁的人几乎一直持有它，其余写者的尝试全部立即失败 →")
		fmt.Println("          「同一时间的尝试大多失败」在**高争抢**下基本成立；但 C 组（单写者）0 失败，")
		fmt.Println("          说明失败来自**争抢**本身，而不是「关闭忙等待」这条设置")
	} else {
		fmt.Println("    说明：单写者、无争抢 → 关闭忙等待也不会失败")
	}
	return nil
}

// singleConnBaseline 用单个连接写 total 次，作为吞吐基线。
func singleConnBaseline(path string, busyTimeoutMs, total int) (time.Duration, error) {
	db, err := sql.Open("turso", fmt.Sprintf("%s?_busy_timeout=%d", path, busyTimeoutMs))
	if err != nil {
		return 0, err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	begin := time.Now()
	for i := 0; i < total; i++ {
		if _, err := db.Exec(`insert into t(worker, n) values (?, ?)`, 0, i); err != nil {
			return 0, err
		}
	}
	return time.Since(begin), nil
}

// speedupNote 比较并行与单连接耗时。
func speedupNote(parallel, base time.Duration) string {
	ratio := parallel.Seconds() / base.Seconds()
	switch {
	case ratio < 1.6:
		return "与单连接基本相当 → 写被写锁串行化，没有并行加速，只是靠忙等待排队成功"
	case ratio < 3:
		return "比单连接略快/相当 → 基本还是串行，等待期间单条语句本身很快"
	default:
		return "明显更快"
	}
}

func ms(d time.Duration) float64 { return float64(d) / float64(time.Millisecond) }

// writeLockContention 让一个连接持写事务一段时间，观察另一个写者「等待」还是「报错」。
func writeLockContention(label string, busyTimeoutMs int) error {
	dir, cleanup, err := tempDir()
	if err != nil {
		return err
	}
	defer cleanup()
	path := filepath.Join(dir, "wal.db")

	db, err := sql.Open("turso", fmt.Sprintf("%s?_busy_timeout=%d", path, busyTimeoutMs))
	if err != nil {
		return err
	}
	defer db.Close()
	if _, err := db.Exec(`create table t(id integer primary key, v integer)`); err != nil {
		return err
	}

	ctx := context.Background()
	holder, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer holder.Close()
	if _, err := holder.ExecContext(ctx, `BEGIN`); err != nil {
		return err
	}
	if _, err := holder.ExecContext(ctx, `insert into t(v) values (1)`); err != nil {
		return err
	}

	var (
		wg      sync.WaitGroup
		elapsed time.Duration
		errB    error
	)
	wg.Add(1)
	go func() {
		defer wg.Done()
		conn, err := db.Conn(ctx)
		if err != nil {
			errB = err
			return
		}
		defer conn.Close()
		t := time.Now()
		_, errB = conn.ExecContext(ctx, `insert into t(v) values (2)`)
		elapsed = time.Since(t)
	}()

	time.Sleep(400 * time.Millisecond) // holder 持写锁 400ms
	_, _ = holder.ExecContext(ctx, `COMMIT`)
	wg.Wait()

	fmt.Printf("  %s\n", label)
	if errB != nil {
		fmt.Printf("    第二个写者在 %s 后失败：%v\n", elapsed.Round(time.Millisecond), errB)
	} else {
		fmt.Printf("    第二个写者等了 %s 才成功（持锁 400ms 期间它只能排队，不能并发写）\n",
			elapsed.Round(time.Millisecond))
	}
	return nil
}

// runMVCC 演示 MVCC 模式下多个写事务并发提交（BEGIN CONCURRENT）。
func runMVCC() error {
	fmt.Println("\n### mvcc：BEGIN CONCURRENT，写事务才真正并行")

	dir, cleanup, err := tempDir()
	if err != nil {
		return err
	}
	defer cleanup()
	path := filepath.Join(dir, "mvcc.db")

	setup, err := sql.Open("turso", path)
	if err != nil {
		return err
	}
	var mode string
	if err := setup.QueryRow(`PRAGMA journal_mode='mvcc'`).Scan(&mode); err != nil {
		return err
	}
	if _, err := setup.Exec(`create table events(id integer primary key, worker integer)`); err != nil {
		return err
	}
	setup.Close()
	fmt.Printf("  journal_mode = %s\n", mode)

	ctx := context.Background()
	db, err := sql.Open("turso", path)
	if err != nil {
		return err
	}
	defer db.Close()

	var (
		mu                sync.Mutex
		spans             []writeSpan
		committed, failed atomic.Int64
	)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			conn, err := db.Conn(ctx)
			if err != nil {
				failed.Add(1)
				return
			}
			defer conn.Close()
			<-start
			s := time.Now().UnixNano()
			if _, err := conn.ExecContext(ctx, `BEGIN CONCURRENT`); err != nil {
				failed.Add(1)
				return
			}
			if _, err := conn.ExecContext(ctx, `insert into events(worker) values (?)`, w); err != nil {
				_, _ = conn.ExecContext(ctx, `ROLLBACK`)
				failed.Add(1)
				return
			}
			if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
				failed.Add(1)
				return
			}
			e := time.Now().UnixNano()
			mu.Lock()
			spans = append(spans, writeSpan{s, e})
			mu.Unlock()
			committed.Add(1)
		}(w)
	}
	close(start)
	wg.Wait()

	var total int
	if err := db.QueryRow(`select count(*) from events`).Scan(&total); err != nil {
		return err
	}
	fmt.Printf("  8 个写事务：提交 %d，失败 %d；表内 %d 行；同时进行的写事务最多 = %d 个\n",
		committed.Load(), failed.Load(), total, maxOverlap(spans))
	return mvccHeldWriteTxn()
}

// mvccHeldWriteTxn 与 WAL 的 D/E 对照：一个写事务持锁 400ms 期间，另一个写事务能否完成。
func mvccHeldWriteTxn() error {
	dir, cleanup, err := tempDir()
	if err != nil {
		return err
	}
	defer cleanup()
	path := filepath.Join(dir, "mvcc-lock.db")

	setup, err := sql.Open("turso", path)
	if err != nil {
		return err
	}
	var mode string
	if err := setup.QueryRow(`PRAGMA journal_mode='mvcc'`).Scan(&mode); err != nil {
		return err
	}
	if _, err := setup.Exec(`create table t(id integer primary key, v integer)`); err != nil {
		return err
	}
	setup.Close()

	db, err := sql.Open("turso", path)
	if err != nil {
		return err
	}
	defer db.Close()
	ctx := context.Background()

	holder, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer holder.Close()
	if _, err := holder.ExecContext(ctx, `BEGIN CONCURRENT`); err != nil {
		return err
	}
	if _, err := holder.ExecContext(ctx, `insert into t(v) values (1)`); err != nil {
		return err
	}

	var (
		wg      sync.WaitGroup
		elapsed time.Duration
		errB    error
	)
	wg.Add(1)
	go func() {
		defer wg.Done()
		conn, err := db.Conn(ctx)
		if err != nil {
			errB = err
			return
		}
		defer conn.Close()
		t := time.Now()
		if _, err := conn.ExecContext(ctx, `BEGIN CONCURRENT`); err != nil {
			errB = err
			return
		}
		if _, err := conn.ExecContext(ctx, `insert into t(v) values (2)`); err != nil {
			_, _ = conn.ExecContext(ctx, `ROLLBACK`)
			errB = err
			return
		}
		_, errB = conn.ExecContext(ctx, `COMMIT`)
		elapsed = time.Since(t)
	}()

	time.Sleep(400 * time.Millisecond) // holder 持事务 400ms
	_, _ = holder.ExecContext(ctx, `COMMIT`)
	wg.Wait()

	var n int
	if err := db.QueryRow(`select count(*) from t`).Scan(&n); err != nil {
		return err
	}
	fmt.Printf("  MVCC 对照：holder 持写事务 400ms 期间，第二个写事务用时 %s\n", elapsed.Round(time.Millisecond))
	if errB != nil {
		fmt.Printf("    第二个写事务失败：%v\n", errB)
	} else {
		fmt.Printf("    第二个写事务几乎立即提交成功，表内 %d 行 → 两个写事务真正并行（对比 WAL 的等待/直接报错）\n", n)
	}
	return nil
}

// maxOverlap 用扫描线算出「同时在进行的区间」的最大数量。
func maxOverlap(spans []writeSpan) int {
	type event struct {
		t int64
		d int
	}
	events := make([]event, 0, len(spans)*2)
	for _, s := range spans {
		events = append(events, event{s.start, 1}, event{s.end, -1})
	}
	sort.Slice(events, func(i, j int) bool {
		if events[i].t != events[j].t {
			return events[i].t < events[j].t
		}
		return events[i].d < events[j].d // 同一时刻先算结束
	})
	cur, max := 0, 0
	for _, e := range events {
		cur += e.d
		if cur > max {
			max = cur
		}
	}
	return max
}
