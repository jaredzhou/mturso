#include <stdlib.h>
#include <string.h>

#include "mturso_internal.h"

typedef struct {
  char *buf;
  size_t len;
  size_t cap;
} strbuf_t;

static void sb_put(strbuf_t *sb, const char *src, size_t len) {
  if (sb->len + len + 1 > sb->cap) {
    size_t cap = sb->cap != 0 ? sb->cap : 256;
    while (cap < sb->len + len + 1) {
      cap *= 2;
    }
    sb->buf = (char *)realloc(sb->buf, cap);
    sb->cap = cap;
  }
  memcpy(sb->buf + sb->len, src, len);
  sb->len += len;
  sb->buf[sb->len] = '\0';
}

static void put_u8(strbuf_t *sb, uint8_t value) {
  sb_put(sb, (const char *)&value, 1);
}

static void put_u32(strbuf_t *sb, uint32_t value) {
  sb_put(sb, (const char *)&value, 4);
}

static void put_i64(strbuf_t *sb, int64_t value) {
  sb_put(sb, (const char *)&value, 8);
}

static void put_f64(strbuf_t *sb, double value) {
  sb_put(sb, (const char *)&value, 8);
}

static void put_str(strbuf_t *sb, const char *value) {
  size_t len = value != NULL ? strlen(value) : 0;
  put_u32(sb, (uint32_t)len);
  if (len > 0) {
    sb_put(sb, value, len);
  }
}

static void put_bytes(strbuf_t *sb, const char *value, int64_t len) {
  put_u32(sb, (uint32_t)(len > 0 ? len : 0));
  if (len > 0 && value != NULL) {
    sb_put(sb, value, (size_t)len);
  }
}

enum { FRAME_END = 0, FRAME_HEADER = 1, FRAME_ROW = 2, FRAME_ERR = 3 };

static int write_all(mturso_fd_t fd, const char *src, size_t len) {
  while (len > 0) {
    size_t written = 0;
    if (mturso_fd_write(fd, src, len, &written) != 0) {
      return -1;
    }
    src += written;
    len -= written;
  }
  return 0;
}

static void frame_begin(strbuf_t *sb, uint8_t tag) {
  sb->len = 0;
  put_u8(sb, tag);
  put_u32(sb, 0);
}

static int flush_frame(mturso_fd_t fd, strbuf_t *sb) {
  uint32_t len = (uint32_t)(sb->len - 5);
  memcpy(sb->buf + 1, &len, 4);
  return write_all(fd, sb->buf, sb->len);
}

void mturso_send_error_frame(mturso_fd_t fd, const char *msg, int kind) {
  const char *message = msg != NULL ? msg : "unknown error";
  strbuf_t sb = {0};
  frame_begin(&sb, FRAME_ERR);
  put_u8(&sb, (uint8_t)kind);
  sb_put(&sb, message, strlen(message));
  (void)flush_frame(fd, &sb);
  free(sb.buf);
}

void mturso_stream_stmt_rows(turso_statement_t *stmt, mturso_fd_t fd) {
  const char *error = NULL;
  strbuf_t sb = {0};
  int64_t n_cols = turso_statement_column_count(stmt);

  frame_begin(&sb, FRAME_HEADER);
  put_u32(&sb, (uint32_t)n_cols);
  for (int64_t i = 0; i < n_cols; i++) {
    put_str(&sb, turso_statement_column_name(stmt, (size_t)i));
    put_str(&sb, turso_statement_column_decltype(stmt, (size_t)i));
  }
  if (flush_frame(fd, &sb) != 0) {
    goto done;
  }

  for (;;) {
    turso_status_code_t status = turso_statement_step(stmt, &error);
    if (status == TURSO_IO) {
      if (turso_statement_run_io(stmt, &error) != TURSO_OK) {
        mturso_send_error_frame(fd, error, MTURSO_ERR_QUERY);
        goto done;
      }
      continue;
    }
    if (status == TURSO_DONE) {
      break;
    }
    if (status != TURSO_ROW) {
      mturso_send_error_frame(fd, error, mturso_kind_from_status(status));
      goto done;
    }

    frame_begin(&sb, FRAME_ROW);
    for (int64_t i = 0; i < n_cols; i++) {
      switch (turso_statement_row_value_kind(stmt, (size_t)i)) {
        case TURSO_TYPE_INTEGER:
          put_u8(&sb, 1);
          put_i64(&sb, turso_statement_row_value_int(stmt, (size_t)i));
          break;
        case TURSO_TYPE_REAL:
          put_u8(&sb, 2);
          put_f64(&sb, turso_statement_row_value_double(stmt, (size_t)i));
          break;
        case TURSO_TYPE_TEXT:
          put_u8(&sb, 3);
          put_bytes(&sb, turso_statement_row_value_bytes_ptr(stmt, (size_t)i),
                    turso_statement_row_value_bytes_count(stmt, (size_t)i));
          break;
        case TURSO_TYPE_BLOB:
          put_u8(&sb, 4);
          put_bytes(&sb, turso_statement_row_value_bytes_ptr(stmt, (size_t)i),
                    turso_statement_row_value_bytes_count(stmt, (size_t)i));
          break;
        default:
          put_u8(&sb, 0);
          break;
      }
    }
    if (flush_frame(fd, &sb) != 0) {
      goto done;
    }
  }

  frame_begin(&sb, FRAME_END);
  put_i64(&sb, turso_statement_n_change(stmt));
  (void)flush_frame(fd, &sb);

done:
  free(sb.buf);
}
