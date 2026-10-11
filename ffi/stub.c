// mturso 的 C 侧：Turso C ABI 的 MoonBit 适配层。
//
// 设计约定（见 notes/turso-binding-guide.md）：
//   1. C 侧从不向 MoonBit 返回 NULL 指针；失败通过 `mturso_last_error()` 报告
//      （空串 = 成功）。这样 MoonBit 侧不需要做空指针判断。
//   2. 连接句柄是 GC 托管的外部对象，finalizer 负责释放 Turso 资源，
//      所以"忘记 close"也不会泄漏原生资源。
//   3. MoonBit 的 Bytes 由运行时保证 NUL 结尾，可直接当 const char* 用。
//   4. 目前是同步调用：所有 Turso 调用都发生在发起调用的线程上。
//      下一步会挪到工作线程 + 门铃 pipe（届时 worker 只许碰 C 内存）。
#include <moonbit.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "turso.h"

// ---------------------------------------------------------------------------
// 全局初始化（进程内一次）与错误槽
// ---------------------------------------------------------------------------

static int g_setup_state = 0; // 0 = 未初始化, 1 = 成功, -1 = 失败
static char g_err[2048];      // 最近一次错误；单线程使用，无需加锁

static void set_err(const char *msg) {
  snprintf(g_err, sizeof(g_err), "%s", msg != NULL ? msg : "unknown error");
}

static void clear_err(void) { g_err[0] = '\0'; }

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

// 可增长字符串缓冲（只在 C 堆上分配，不碰 MoonBit GC）
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

// ---------------------------------------------------------------------------
// 连接句柄
// ---------------------------------------------------------------------------

typedef struct {
  const turso_database_t *db;
  turso_connection_t *conn;
} mturso_conn_t;

static void conn_finalize(void *self) {
  mturso_conn_t *c = (mturso_conn_t *)self;
  if (c->conn != NULL) {
    turso_connection_deinit(c->conn);
    c->conn = NULL;
  }
  if (c->db != NULL) {
    turso_database_deinit(c->db);
    c->db = NULL;
  }
  // 注意：不要释放容器本身，它由 GC 管理
}

static mturso_conn_t *conn_new(void) {
  mturso_conn_t *h =
      (mturso_conn_t *)moonbit_make_external_object(conn_finalize, sizeof(mturso_conn_t));
  memset(h, 0, sizeof(mturso_conn_t));
  return h;
}

// ---------------------------------------------------------------------------
// 导出的 FFI
// ---------------------------------------------------------------------------

MOONBIT_FFI_EXPORT
mturso_conn_t *mturso_open(moonbit_bytes_t path) {
  clear_err();
  ensure_setup();

  mturso_conn_t *h = conn_new();
  if (g_setup_state != 1) {
    if (g_err[0] == '\0') {
      set_err("turso_setup failed");
    }
    return h;
  }

  turso_database_config_t cfg = {0};
  cfg.path = (const char *)path; // Bytes 由运行时保证 NUL 结尾
  cfg.async_io = 0;              // 同步模式：库在调用线程上推进 I/O

  const char *err = NULL;
  if (turso_database_new(&cfg, &h->db, &err) != TURSO_OK) {
    set_err(err);
    return h;
  }
  if (turso_database_open(h->db, &err) != TURSO_OK) {
    set_err(err);
    return h;
  }
  if (turso_database_connect(h->db, &h->conn, &err) != TURSO_OK) {
    set_err(err);
    return h;
  }
  return h;
}

// 用 step 把语句跑到 TURSO_DONE。
// 注意：C API 要求同一个语句不能在 step / execute 之间混用，这里统一用 step。
static int step_to_done(turso_statement_t *stmt, const char **err) {
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
    return -1;
  }
}

MOONBIT_FFI_EXPORT
int64_t mturso_exec(mturso_conn_t *conn, moonbit_bytes_t sql) {
  clear_err();
  if (conn == NULL || conn->conn == NULL) {
    set_err("connection is not open");
    return -1;
  }

  const char *err = NULL;
  turso_statement_t *stmt = NULL;
  if (turso_connection_prepare_single(conn->conn, (const char *)sql, &stmt, &err) != TURSO_OK) {
    set_err(err);
    return -1;
  }

  int rc = step_to_done(stmt, &err);
  int64_t changes = turso_statement_n_change(stmt);
  turso_statement_deinit(stmt);

  if (rc != 0) {
    set_err(err);
    return -1;
  }
  return changes;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_query(mturso_conn_t *conn, moonbit_bytes_t sql) {
  clear_err();
  if (conn == NULL || conn->conn == NULL) {
    set_err("connection is not open");
    return bytes_empty();
  }

  const char *err = NULL;
  turso_statement_t *stmt = NULL;
  if (turso_connection_prepare_single(conn->conn, (const char *)sql, &stmt, &err) != TURSO_OK) {
    set_err(err);
    return bytes_empty();
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
        default: // BLOB 等先简化处理
          sb_puts(&sb, "<blob>");
          break;
      }
    }
  }

  turso_statement_deinit(stmt);

  if (failed) {
    set_err(err);
    free(sb.buf);
    return bytes_empty();
  }

  moonbit_bytes_t out = bytes_dup(sb.buf != NULL ? sb.buf : "", (int32_t)sb.len);
  free(sb.buf);
  return out;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_last_error(void) {
  return bytes_dup(g_err, (int32_t)strlen(g_err));
}

MOONBIT_FFI_EXPORT
void mturso_close(mturso_conn_t *conn) {
  if (conn == NULL) {
    return;
  }
  if (conn->conn != NULL) {
    turso_connection_deinit(conn->conn);
    conn->conn = NULL;
  }
  if (conn->db != NULL) {
    turso_database_deinit(conn->db);
    conn->db = NULL;
  }
}
