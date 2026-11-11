// retry_tx：重试单位是整个事务；只重试 Busy | Conflict；full-jitter 指数退避。

///|
/// 重试预算。
pub(all) struct RetryOptions {
  attempts : Int
  base_delay_ms : Int
  max_delay_ms : Int
  budget_ms : Int?
} derive(Eq, Debug)

///|
pub fn RetryOptions::default() -> RetryOptions {
  { attempts: 10, base_delay_ms: 1, max_delay_ms: 50, budget_ms: None }
}

///|
fn is_retryable(e : TursoError) -> Bool {
  match e {
    TursoError::Busy(_) | TursoError::Conflict(_) => true
    _ => false
  }
}

///|
/// `begin_func` + 重试。重试单位是**整个事务**；重试的是「可重试」那一档
/// （`Busy` | `Conflict`）。撞到哪个取决于连接的运行模式：
/// 写者互斥 → `Busy`；MVCC + `BEGIN CONCURRENT` → `Conflict`。
///
/// 没有语句级重试助手：读不需要重试，写要能重试就显式走事务。
pub async fn[T, B : TxBeginner] retry_tx(
  beginner : B,
  f : async (DbTx) -> T raise TursoError,
  opts? : RetryOptions,
) -> T raise TursoError {
  let o = match opts {
    None => RetryOptions::default()
    Some(o) => o
  }
  let rng = @random.Rand::chacha8()
  let start = @async.now()
  let mut attempt = 1
  for ;; {
    try begin_func(beginner, f) catch {
      e => {
        if !is_retryable(e) || attempt >= o.attempts {
          raise e
        }
        // full jitter: [0, min(base << (n-1), max)]
        let cap = if o.base_delay_ms <= 0 {
          0
        } else {
          let shifted = o.base_delay_ms << (attempt - 1)
          if shifted > o.max_delay_ms { o.max_delay_ms } else { shifted }
        }
        let delay = if cap <= 0 { 0 } else { rng.int(limit=cap) }
        if o.budget_ms is Some(b) &&
          @async.now() - start + delay.to_int64() > b.to_int64() {
          raise e
        }
        if delay > 0 {
          @async.sleep(delay)
        }
        attempt = attempt + 1
      }
    } noraise {
      r => return r
    }
  }
}
