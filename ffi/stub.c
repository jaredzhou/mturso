// mturso 的 C 侧：Turso C ABI 的 MoonBit 适配层。
//
// 句柄模型（对齐 Go 绑定的用法）：
//   一个 Database 可以 connect 出**多个** Connection（`turso_database_connect` 可重复调用）。
//   两者都是 GC 托管的外部对象，各自的 finalizer 负责释放原生资源。
//   ⚠️ MoonBit 侧必须让 Connection 持有 Database 的引用，否则 GC 可能先回收 Database。
//
// 同步 vs 异步：
//   - `*_exec` / `*_query`：在调用线程上直接跑（阻塞）。适合不需要 async 的场合。
//   - `submit_*` + `take_*`：把语句交给**每连接一个工作线程**执行，完成后往该连接的
//     门铃 pipe 写 1 字节；MoonBit 侧 await 门铃（RawFdStream）后再 take 结果。
//     这样阻塞只发生在工作线程上，事件循环线程不被卡住。
//
// 约定（见 notes/turso-binding-guide.md）：
//   1. C 侧从不向 MoonBit 返回 NULL；失败通过 `mturso_last_error()`（全局，给 open/connect）
//      和 `mturso_conn_last_error()`（每连接，给 job）报告。空串 = 成功。
//   2. **工作线程只碰 C 内存**：提交时把 SQL 拷贝到 C 堆，绝不引用 MoonBit 对象；
//      结果也在 C 堆上，由 MoonBit 线程在 take 时拷进 Bytes。
//   3. 同一个语句不要混用 step / execute（这里统一用 step）。
#include <errno.h>
#include <fcntl.h>
#include <moonbit.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "turso.h"

// ---------------------------------------------------------------------------
// 全局初始化与全局错误槽（只给 open / connect 用；job 的错误在连接里）
// ---------------------------------------------------------------------------

static int g_setup_state = 0; // 0 = 未初始化, 1 = 成功, -1 = 失败
static char g_err[2048];

// 错误分类：消息仍是文本，分类给 MoonBit 侧做模式匹配（Busy / Conflict 是可重试信号）。
enum {
  MTURSO_ERR_NONE = 0,
  MTURSO_ERR_QUERY = 1,
  MTURSO_ERR_BUSY = 2,
  MTURSO_ERR_CONFLICT = 3,
  MTURSO_ERR_CONNECTION = 4,
};

static int g_kind = MTURSO_ERR_NONE;

static int kind_from_status(turso_status_code_t st) {
  switch (st) {
    case TURSO_BUSY:
      return MTURSO_ERR_BUSY;
    case TURSO_BUSY_SNAPSHOT:
      return MTURSO_ERR_CONFLICT;
    default:
      return MTURSO_ERR_QUERY;
  }
}

static void set_err_kind(const char *msg, int kind) {
  snprintf(g_err, sizeof(g_err), "%s", msg != NULL ? msg : "unknown error");
  g_kind = kind;
}

static void set_err(const char *msg) { set_err_kind(msg, MTURSO_ERR_CONNECTION); }

static void clear_err(void) {
  g_err[0] = '\0';
  g_kind = MTURSO_ERR_NONE;
}

static void ensure_setup(void) {
  if (g_setup_state != 0) {
    return;
  }
  turso_config_t cfg = {0};
  const char *err = NULL;
  if (turso_setup(&cfg, &err) != TURSO_OK) {
    g_setup_state = -1;
    set_err(err);
    return;
  }
  g_setup_state = 1;
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

static moonbit_bytes_t bytes_dup(const char *src, int32_t len) {
  moonbit_bytes_t b = moonbit_make_bytes(len, 0);
  if (len > 0 && src != NULL) {
    memcpy(b, src, (size_t)len);
  }
  return b;
}

static moonbit_bytes_t bytes_empty(void) { return moonbit_make_bytes(0, 0); }

typedef struct {
  char *buf;
  size_t len;
  size_t cap;
} strbuf_t;

static void sb_put(strbuf_t *sb, const char *s, size_t n) {
  if (sb->len + n + 1 > sb->cap) {
    size_t cap = sb->cap != 0 ? sb->cap : 256;
    while (cap < sb->len + n + 1) {
      cap *= 2;
    }
    sb->buf = (char *)realloc(sb->buf, cap);
    sb->cap = cap;
  }
  memcpy(sb->buf + sb->len, s, n);
  sb->len += n;
  sb->buf[sb->len] = '\0';
}

static void sb_puts(strbuf_t *sb, const char *s) { sb_put(sb, s, strlen(s)); }

static void set_errbuf(char *buf, size_t len, const char *msg) {
  snprintf(buf, len, "%s", msg != NULL ? msg : "unknown error");
}

// ---------------------------------------------------------------------------
// 语句执行（C 字符串接口，供同步路径与工作线程共用）
// ---------------------------------------------------------------------------

// 用 step 把语句跑到 TURSO_DONE（不混用 execute）
static int step_to_done(turso_statement_t *stmt, const char **err, int *out_kind) {
  for (;;) {
    turso_status_code_t st = turso_statement_step(stmt, err);
    if (st == TURSO_ROW) {
      continue;
    }
    if (st == TURSO_IO) {
      if (turso_statement_run_io(stmt, err) != TURSO_OK) {
        return -1;
      }
      continue;
    }
    if (st == TURSO_DONE) {
      return 0;
    }
    if (out_kind != NULL) {
      *out_kind = kind_from_status(st);
    }
    return -1;
  }
}

// 执行非查询语句；成功返回受影响行数，失败返回 -1 并写 errbuf
static int64_t do_exec(turso_connection_t *conn, const char *sql, char *errbuf, size_t errlen,
                       int *out_kind) {
  const char *err = NULL;
  turso_statement_t *stmt = NULL;
  turso_status_code_t pst = turso_connection_prepare_single(conn, sql, &stmt, &err);
  if (pst != TURSO_OK) {
    if (out_kind != NULL) {
      *out_kind = kind_from_status(pst);
    }
    set_errbuf(errbuf, errlen, err);
    return -1;
  }
  int rc = step_to_done(stmt, &err, out_kind);
  int64_t changes = turso_statement_n_change(stmt);
  turso_statement_deinit(stmt);
  if (rc != 0) {
    set_errbuf(errbuf, errlen, err);
    return -1;
  }
  return changes;
}

// 执行查询，结果渲染成制表符/换行分隔的文本（malloc 出来，调用方 free）
static char *do_query(turso_connection_t *conn, const char *sql, int32_t *out_len, char *errbuf,
                      size_t errlen, int *out_kind) {
  const char *err = NULL;
  turso_statement_t *stmt = NULL;
  turso_status_code_t pst = turso_connection_prepare_single(conn, sql, &stmt, &err);
  if (pst != TURSO_OK) {
    if (out_kind != NULL) {
      *out_kind = kind_from_status(pst);
    }
    set_errbuf(errbuf, errlen, err);
    return NULL;
  }

  strbuf_t sb = {0};
  int first_row = 1;
  int failed = 0;

  for (;;) {
    turso_status_code_t st = turso_statement_step(stmt, &err);
    if (st == TURSO_IO) {
      if (turso_statement_run_io(stmt, &err) != TURSO_OK) {
        failed = 1;
        break;
      }
      continue;
    }
    if (st == TURSO_DONE) {
      break;
    }
    if (st != TURSO_ROW) {
      if (out_kind != NULL) {
        *out_kind = kind_from_status(st);
      }
      failed = 1;
      break;
    }
    if (!first_row) {
      sb_put(&sb, "\n", 1);
    }
    first_row = 0;

    int64_t ncol = turso_statement_column_count(stmt);
    for (int64_t i = 0; i < ncol; i++) {
      if (i > 0) {
        sb_put(&sb, "\t", 1);
      }
      char tmp[64];
      switch (turso_statement_row_value_kind(stmt, (size_t)i)) {
        case TURSO_TYPE_INTEGER: {
          int n = snprintf(tmp, sizeof(tmp), "%lld",
                           (long long)turso_statement_row_value_int(stmt, (size_t)i));
          sb_put(&sb, tmp, (size_t)n);
          break;
        }
        case TURSO_TYPE_REAL: {
          int n = snprintf(tmp, sizeof(tmp), "%g",
                           turso_statement_row_value_double(stmt, (size_t)i));
          sb_put(&sb, tmp, (size_t)n);
          break;
        }
        case TURSO_TYPE_TEXT: {
          int64_t n = turso_statement_row_value_bytes_count(stmt, (size_t)i);
          const char *p = turso_statement_row_value_bytes_ptr(stmt, (size_t)i);
          if (p != NULL && n > 0) {
            sb_put(&sb, p, (size_t)n);
          }
          break;
        }
        case TURSO_TYPE_NULL:
          sb_puts(&sb, "NULL");
          break;
        default: // BLOB 等先简化
          sb_puts(&sb, "<blob>");
          break;
      }
    }
  }

  turso_statement_deinit(stmt);

  if (failed) {
    set_errbuf(errbuf, errlen, err);
    free(sb.buf);
    return NULL;
  }
  if (sb.buf == NULL) {
    sb.buf = (char *)calloc(1, 1);
  }
  *out_len = (int32_t)sb.len;
  return sb.buf;
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 测试辅助：注册标量函数 `turso_sleep(ms)` —— 在**执行该语句的线程**上睡 ms 毫秒。
// 用来验证并发：慢查询睡在它自己的工作线程上，不应影响别的连接。
// ---------------------------------------------------------------------------
static turso_value_t turso_sleep_scalar(uintptr_t context, int32_t argc, const turso_value_t *argv,
                                     turso_context_destructor_t context_destructor,
                                     turso_value_destructor_t value_destructor) {
  (void)context;
  (void)context_destructor;
  (void)value_destructor;
  int64_t ms = 0;
  if (argc >= 1 && argv[0].value_type == TURSO_EXTENSION_VALUE_INTEGER) {
    ms = argv[0].value.int_value;
  }
  if (ms > 0) {
    usleep((useconds_t)(ms * 1000));
  }
  turso_value_t out = {0};
  out.value_type = TURSO_EXTENSION_VALUE_INTEGER;
  out.value.int_value = ms;
  return out;
}

static void register_test_functions(turso_connection_t *conn) {
  const char *err = NULL;
  // deterministic = false：它会睡，不能被常量折叠
  turso_connection_register_scalar_function(conn, "turso_sleep", 1, false, 0, turso_sleep_scalar, NULL,
                                            NULL, &err);
}

typedef struct {
  const turso_database_t *db;
} mturso_db_t;

static void db_finalize(void *self) {
  mturso_db_t *h = (mturso_db_t *)self;
  if (h->db != NULL) {
    turso_database_deinit(h->db);
    h->db = NULL;
  }
}

MOONBIT_FFI_EXPORT
mturso_db_t *mturso_db_open(moonbit_bytes_t path) {
  clear_err();
  ensure_setup();

  mturso_db_t *h = (mturso_db_t *)moonbit_make_external_object(db_finalize, sizeof(mturso_db_t));
  memset(h, 0, sizeof(mturso_db_t));
  if (g_setup_state != 1) {
    if (g_err[0] == '\0') {
      set_err("turso_setup failed");
    }
    return h;
  }

  turso_database_config_t cfg = {0};
  cfg.path = (const char *)path; // Bytes 保证 NUL 结尾
  cfg.async_io = 0;              // 同步模式：谁调谁推进 I/O

  const char *err = NULL;
  if (turso_database_new(&cfg, &h->db, &err) != TURSO_OK) {
    set_err(err);
    return h;
  }
  if (turso_database_open(h->db, &err) != TURSO_OK) {
    set_err(err);
  }
  return h;
}

MOONBIT_FFI_EXPORT
void mturso_db_close(mturso_db_t *db) {
  if (db == NULL || db->db == NULL) {
    return;
  }
  turso_database_deinit(db->db);
  db->db = NULL;
}

// ---------------------------------------------------------------------------
// Connection（一个 Database 可以开多个；每个连接自带一个工作线程 + 门铃）
// ---------------------------------------------------------------------------

typedef struct {
  turso_connection_t *conn;

  // 工作线程与任务槽
  pthread_t worker;
  int worker_started;
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int has_job;
  int shutdown;
  int job_is_query;
  char *job_sql;       // C 堆（从 MoonBit 拷贝），worker 负责 free
  int job_done;
  char *result;        // worker 写的查询结果（C 堆）
  int32_t result_len;
  int64_t changes;     // exec 的受影响行数
  int failed;
  int kind;            // 上一条 job 的错误分类（见 MTURSO_ERR_*）
  char err[1024];      // 每连接错误：worker 写、MoonBit 线程读

  // 门铃：worker 写 1 字节，MoonBit 侧把 bell_r 包成 RawFdStream
  int bell_r;          // -1 = 已交给 MoonBit（或未创建）
  int bell_w;
} mturso_conn_t;

static void *conn_worker(void *arg) {
  mturso_conn_t *h = (mturso_conn_t *)arg;
  for (;;) {
    pthread_mutex_lock(&h->mu);
    while (!h->has_job && !h->shutdown) {
      pthread_cond_wait(&h->cv, &h->mu);
    }
    if (h->shutdown && !h->has_job) {
      pthread_mutex_unlock(&h->mu);
      break;
    }
    char *sql = h->job_sql;
    int is_query = h->job_is_query;
    h->job_sql = NULL;
    h->has_job = 0;
    pthread_mutex_unlock(&h->mu);

    // 阻塞执行 —— 只发生在工作线程上
    char errbuf[1024] = {0};
    char *result = NULL;
    int32_t result_len = 0;
    int64_t changes = 0;
    int failed = 0;
    int kind = MTURSO_ERR_NONE;
    if (h->conn == NULL) {
      set_errbuf(errbuf, sizeof(errbuf), "connection is not open");
      failed = 1;
      kind = MTURSO_ERR_CONNECTION;
    } else if (is_query) {
      result = do_query(h->conn, sql, &result_len, errbuf, sizeof(errbuf), &kind);
      failed = (result == NULL);
    } else {
      changes = do_exec(h->conn, sql, errbuf, sizeof(errbuf), &kind);
      failed = (changes < 0);
    }
    free(sql);

    pthread_mutex_lock(&h->mu);
    h->result = result;
    h->result_len = result_len;
    h->changes = changes;
    h->failed = failed;
    h->kind = kind;
    snprintf(h->err, sizeof(h->err), "%s", errbuf);
    h->job_done = 1;
    pthread_mutex_unlock(&h->mu);

    // 敲门铃（先发布结果，再敲）
    char b = 1;
    ssize_t n = write(h->bell_w, &b, 1);
    (void)n;
  }
  return NULL;
}

static void conn_finalize(void *self) {
  mturso_conn_t *h = (mturso_conn_t *)self;

  if (h->worker_started) {
    pthread_mutex_lock(&h->mu);
    h->shutdown = 1;
    pthread_cond_signal(&h->cv);
    pthread_mutex_unlock(&h->mu);
    pthread_join(h->worker, NULL);
    h->worker_started = 0;
  }
  if (h->job_sql != NULL) free(h->job_sql);
  if (h->result != NULL) free(h->result);
  if (h->bell_w >= 0) close(h->bell_w);
  if (h->bell_r >= 0) close(h->bell_r); // 若已交给 MoonBit 则是 -1
  if (h->conn != NULL) {
    turso_connection_deinit(h->conn);
    h->conn = NULL;
  }
  pthread_mutex_destroy(&h->mu);
  pthread_cond_destroy(&h->cv);
}

MOONBIT_FFI_EXPORT
mturso_conn_t *mturso_db_connect(mturso_db_t *db) {
  clear_err();
  mturso_conn_t *h =
      (mturso_conn_t *)moonbit_make_external_object(conn_finalize, sizeof(mturso_conn_t));
  memset(h, 0, sizeof(mturso_conn_t));
  h->bell_r = -1;
  h->bell_w = -1;
  pthread_mutex_init(&h->mu, NULL);
  pthread_cond_init(&h->cv, NULL);

  if (db == NULL || db->db == NULL) {
    set_err("database is not open");
    return h;
  }
  const char *err = NULL;
  if (turso_database_connect(db->db, &h->conn, &err) != TURSO_OK) {
    set_err(err);
    return h;
  }
  register_test_functions(h->conn);

  // 门铃 pipe：读端设成非阻塞，交给 MoonBit 后走事件循环（epoll）
  int fds[2];
  if (pipe(fds) == 0) {
    h->bell_r = fds[0];
    h->bell_w = fds[1];
    int flags = fcntl(h->bell_r, F_GETFL, 0);
    if (flags >= 0) {
      fcntl(h->bell_r, F_SETFL, flags | O_NONBLOCK);
    }
  }

  if (pthread_create(&h->worker, NULL, conn_worker, h) == 0) {
    h->worker_started = 1;
  } else {
    set_err("failed to start worker thread");
  }
  return h;
}

MOONBIT_FFI_EXPORT
void mturso_conn_close(mturso_conn_t *conn) {
  if (conn == NULL || conn->conn == NULL) {
    return;
  }
  turso_connection_deinit(conn->conn);
  conn->conn = NULL;
}

// ---- 同步路径（在调用线程上跑） ----

MOONBIT_FFI_EXPORT
int64_t mturso_conn_exec(mturso_conn_t *conn, moonbit_bytes_t sql) {
  clear_err();
  if (conn == NULL || conn->conn == NULL) {
    set_err("connection is not open");
    return -1;
  }
  char errbuf[1024] = {0};
  int kind = MTURSO_ERR_NONE;
  int64_t changes = do_exec(conn->conn, (const char *)sql, errbuf, sizeof(errbuf), &kind);
  if (changes < 0) {
    set_err_kind(errbuf, kind);
  }
  return changes;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_conn_query(mturso_conn_t *conn, moonbit_bytes_t sql) {
  clear_err();
  if (conn == NULL || conn->conn == NULL) {
    set_err("connection is not open");
    return bytes_empty();
  }
  char errbuf[1024] = {0};
  int32_t len = 0;
  int kind = MTURSO_ERR_NONE;
  char *result =
      do_query(conn->conn, (const char *)sql, &len, errbuf, sizeof(errbuf), &kind);
  if (result == NULL) {
    set_err_kind(errbuf, kind);
    return bytes_empty();
  }
  moonbit_bytes_t out = bytes_dup(result, len);
  free(result);
  return out;
}

// ---- 异步路径（提交给本连接的工作线程；完成后敲门铃） ----

static void submit_job(mturso_conn_t *conn, moonbit_bytes_t sql, int is_query) {
  if (conn == NULL || conn->conn == NULL) {
    set_err("connection is not open");
    return;
  }
  if (!conn->worker_started) {
    set_err("worker thread is not running");
    return;
  }
  // 关键：把 SQL 拷贝到 C 堆 —— 工作线程绝不能引用 MoonBit 内存
  char *copy = strdup((const char *)sql);
  pthread_mutex_lock(&conn->mu);
  if (conn->has_job) {
    pthread_mutex_unlock(&conn->mu);
    free(copy);
    set_err("a job is already in flight on this connection");
    return;
  }
  if (conn->result != NULL) {
    free(conn->result);
    conn->result = NULL;
  }
  conn->job_sql = copy;
  conn->job_is_query = is_query;
  conn->job_done = 0;
  conn->failed = 0;
  conn->err[0] = '\0';
  conn->has_job = 1;
  pthread_cond_signal(&conn->cv);
  pthread_mutex_unlock(&conn->mu);
}

MOONBIT_FFI_EXPORT
void mturso_submit_query(mturso_conn_t *conn, moonbit_bytes_t sql) {
  clear_err();
  submit_job(conn, sql, 1);
}

MOONBIT_FFI_EXPORT
void mturso_submit_exec(mturso_conn_t *conn, moonbit_bytes_t sql) {
  clear_err();
  submit_job(conn, sql, 0);
}

// 把门铃读端交给 MoonBit（RawFdStream 接管所有权）。只能拿一次。
MOONBIT_FFI_EXPORT
int32_t mturso_conn_bell_fd(mturso_conn_t *conn) {
  clear_err();
  if (conn == NULL || conn->bell_r < 0) {
    set_err("doorbell is not available");
    return -1;
  }
  int32_t fd = conn->bell_r;
  conn->bell_r = -1; // 所有权已转移
  return fd;
}

// 取回查询结果（在 MoonBit 线程上把 C 堆的结果拷进 Bytes）
MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_take_query(mturso_conn_t *conn) {
  if (conn == NULL) {
    set_err("connection is null");
    return bytes_empty();
  }
  pthread_mutex_lock(&conn->mu);
  int failed = conn->failed;
  char errbuf[1024];
  snprintf(errbuf, sizeof(errbuf), "%s", conn->err);
  char *result = conn->result;
  int32_t len = conn->result_len;
  conn->result = NULL;
  conn->result_len = 0;
  conn->job_done = 0;
  pthread_mutex_unlock(&conn->mu);

  if (failed) {
    if (result != NULL) free(result);
    set_err_kind(errbuf, conn->kind);
    return bytes_empty();
  }
  moonbit_bytes_t out = bytes_dup(result != NULL ? result : "", len);
  if (result != NULL) free(result);
  clear_err();
  return out;
}

// 取回 exec 的受影响行数
MOONBIT_FFI_EXPORT
int64_t mturso_take_exec(mturso_conn_t *conn) {
  if (conn == NULL) {
    set_err("connection is null");
    return -1;
  }
  pthread_mutex_lock(&conn->mu);
  int failed = conn->failed;
  char errbuf[1024];
  snprintf(errbuf, sizeof(errbuf), "%s", conn->err);
  int64_t changes = conn->changes;
  conn->job_done = 0;
  pthread_mutex_unlock(&conn->mu);

  if (failed) {
    set_err_kind(errbuf, conn->kind);
    return -1;
  }
  clear_err();
  return changes;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_last_error(void) {
  return bytes_dup(g_err, (int32_t)strlen(g_err));
}

// 上一条错误的分类（0 = 无错误；见 MTURSO_ERR_*）。
MOONBIT_FFI_EXPORT
int32_t mturso_last_error_kind(void) { return (int32_t)g_kind; }
