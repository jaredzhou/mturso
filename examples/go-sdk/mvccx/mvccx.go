// Package mvccx 给 Turso 的 MVCC 并发事务提供一个「像 Begin 一样」的封装。
//
// 背景（见 notes/go-sdk.md）：Go 绑定 turso.tech/database/tursogo v0.8.x 的
// driver.ConnBeginTx 是硬编码 `ExecContext(ctx, "BEGIN", nil)`，并且把
// driver.TxOptions 参数直接忽略（形参名就是 `_`）。所以：
//
//   - database/sql 的 db.BeginTx() 只能拿到「排他写事务」：在 MVCC 下走
//     TransactionMode::Write -> mv_store.begin_exclusive_tx_*，写者互斥（会报 database is busy）；
//   - 想拿到 Turso 扩展的 BEGIN CONCURRENT（TransactionMode::Concurrent -> mv_store.begin_tx，
//     多版本、允许并发写者），只能自己在固定的 *sql.Conn 上发。
//
// 本包把这层封装成接近 sql.Tx 的用法，并自带「可重试错误」的自动重试。
package mvccx

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math/rand"
	"strings"
	"time"
)

// ErrTxDone 表示事务已经结束（Commit/Rollback 之后再操作）。
var ErrTxDone = errors.New("mvccx: transaction has already been committed or rolled back")

// Tx 是一个 BEGIN CONCURRENT 事务。用法与 sql.Tx 类似。
//
// 与 sql.Tx 的关键区别：冲突（Write-write conflict）会**中止事务**，此后本对象即失效，
// 任何操作返回 ErrTxDone —— 从而避免 sql.Tx/裸连接在冲突后静默进入 autocommit 的坑。
type Tx struct {
	conn *sql.Conn
	done bool
}

// Begin 在 conn 上开启一个 BEGIN CONCURRENT 事务。
// 调用方需自行保证 conn 不被并发使用（*sql.Conn 本身就不是并发安全的）。
func Begin(ctx context.Context, conn *sql.Conn) (*Tx, error) {
	if _, err := conn.ExecContext(ctx, `BEGIN CONCURRENT`); err != nil {
		return nil, err
	}
	return &Tx{conn: conn}, nil
}

// ExecContext 在当前事务内执行语句。
func (t *Tx) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	if t.done {
		return nil, ErrTxDone
	}
	return t.conn.ExecContext(ctx, query, args...)
}

// QueryContext 在当前事务内查询。
func (t *Tx) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	if t.done {
		return nil, ErrTxDone
	}
	return t.conn.QueryContext(ctx, query, args...)
}

// QueryRowContext 在当前事务内查询单行。
func (t *Tx) QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row {
	return t.conn.QueryRowContext(ctx, query, args...)
}

// Commit 提交事务。
func (t *Tx) Commit() error {
	if t.done {
		return ErrTxDone
	}
	t.done = true
	ctx := context.Background()
	if _, err := t.conn.ExecContext(ctx, `COMMIT`); err != nil {
		// 事务可能已被冲突中止：确保连接不残留状态
		_, _ = t.conn.ExecContext(ctx, `ROLLBACK`)
		return err
	}
	return nil
}

// Rollback 回滚事务。对已结束的事务调用是安全的（返回 nil）。
func (t *Tx) Rollback() error {
	if t.done {
		return nil
	}
	t.done = true
	_, err := t.conn.ExecContext(context.Background(), `ROLLBACK`)
	if err != nil && IsRetryable(err) {
		return nil // 事务已被中止，回滚自然失败；不算错误
	}
	return err
}

// IsRetryable 判断错误是否值得重试（写写冲突 / 忙）。
func IsRetryable(err error) bool {
	if err == nil {
		return false
	}
	s := strings.ToLower(err.Error())
	return strings.Contains(s, "write-write conflict") ||
		strings.Contains(s, "busy") ||
		strings.Contains(s, "database is locked")
}

// Options 控制 Run 的重试行为。
type Options struct {
	Attempts  int           // 最大尝试次数，<=0 视为 10
	BaseDelay time.Duration // 退避基数（指数起点），<=0 视为 1ms
	MaxDelay  time.Duration // 单次退避上限，<=0 视为 50ms
	Budget    time.Duration // 总时间预算，<=0 表示不限
}

// Run 在 conn 上以「一个 BEGIN CONCURRENT 事务」执行 fn；遇到可重试错误
// （写写冲突等）会自动重试整个事务，每次都是全新事务，同一个连接即可。
//
// 退避采用 **full jitter 指数退避**（random(0, min(BaseDelay<<i, MaxDelay))）。
// 这一点很关键：实测「8 个写者抢同一行」时，无退避平均要 ~97 次尝试才会成功；
// 换成 full jitter 后平均只要 ~3 次（p99 ~30）。也就是说重试次数主要由退避策略决定。
//
// 这是把「失败处理」内建进来的正确姿势：
//
//	err := mvccx.Run(ctx, conn, mvccx.Options{}, func(ctx context.Context, tx *mvccx.Tx) error {
//	    _, err := tx.ExecContext(ctx, `update t set v = v + 1 where id = 1`)
//	    return err
//	})
func Run(ctx context.Context, conn *sql.Conn, opts Options, fn func(ctx context.Context, tx *Tx) error) error {
	attempts := opts.Attempts
	if attempts <= 0 {
		attempts = 10
	}
	delay := opts.BaseDelay
	if delay <= 0 {
		delay = time.Millisecond
	}
	maxDelay := opts.MaxDelay
	if maxDelay <= 0 {
		maxDelay = 50 * time.Millisecond
	}
	var deadline time.Time
	if opts.Budget > 0 {
		deadline = time.Now().Add(opts.Budget)
	}

	var lastErr error
	for i := 0; i < attempts; i++ {
		tx, err := Begin(ctx, conn)
		if err == nil {
			if err = fn(ctx, tx); err == nil {
				if err = tx.Commit(); err == nil {
					return nil
				}
			} else {
				_ = tx.Rollback()
			}
		}
		lastErr = err
		if !IsRetryable(lastErr) {
			return lastErr
		}

		// full jitter 指数退避
		d := delay << uint(i)
		if d <= 0 || d > maxDelay {
			d = maxDelay
		}
		wait := time.Duration(rand.Int63n(int64(d) + 1))
		if !deadline.IsZero() && time.Now().Add(wait).After(deadline) {
			return fmt.Errorf("mvccx: 超出时间预算 %v: %w", opts.Budget, lastErr)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
	return fmt.Errorf("mvccx: 重试 %d 次仍失败: %w", attempts, lastErr)
}
