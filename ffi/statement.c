#include <string.h>

#include "mturso_internal.h"

typedef struct {
  turso_statement_t *stmt;
  int64_t tail;
} mturso_stmt_t;

static void stmt_finalize(void *self) {
  mturso_stmt_t *handle = (mturso_stmt_t *)self;
  if (handle->stmt != NULL) {
    turso_statement_deinit(handle->stmt);
    handle->stmt = NULL;
  }
}

MOONBIT_FFI_EXPORT
mturso_stmt_t *mturso_conn_prepare(mturso_conn_t *conn, moonbit_bytes_t sql) {
  mturso_clear_err();
  mturso_stmt_t *handle = (mturso_stmt_t *)moonbit_make_external_object(
      stmt_finalize, sizeof(mturso_stmt_t));
  memset(handle, 0, sizeof(mturso_stmt_t));
  turso_connection_t *raw = mturso_conn_raw(conn);
  if (raw == NULL) {
    mturso_set_err("connection is not open");
    return handle;
  }

  const char *err = NULL;
  turso_status_code_t status =
      turso_connection_prepare_single(raw, (const char *)sql, &handle->stmt, &err);
  if (status != TURSO_OK) {
    mturso_set_err_kind(err, mturso_kind_from_status(status));
  }
  return handle;
}

MOONBIT_FFI_EXPORT
mturso_stmt_t *mturso_conn_prepare_first(mturso_conn_t *conn,
                                         moonbit_bytes_t sql) {
  mturso_clear_err();
  mturso_stmt_t *handle = (mturso_stmt_t *)moonbit_make_external_object(
      stmt_finalize, sizeof(mturso_stmt_t));
  memset(handle, 0, sizeof(mturso_stmt_t));
  turso_connection_t *raw = mturso_conn_raw(conn);
  if (raw == NULL) {
    mturso_set_err("connection is not open");
    return handle;
  }

  const char *err = NULL;
  size_t tail = 0;
  turso_status_code_t status = turso_connection_prepare_first(
      raw, (const char *)sql, &handle->stmt, &tail, &err);
  if (status != TURSO_OK) {
    mturso_set_err_kind(err, mturso_kind_from_status(status));
  }
  handle->tail = (int64_t)tail;
  return handle;
}

MOONBIT_FFI_EXPORT
void mturso_stmt_deinit(mturso_stmt_t *stmt) {
  if (stmt == NULL || stmt->stmt == NULL) {
    return;
  }
  turso_statement_deinit(stmt->stmt);
  stmt->stmt = NULL;
}

MOONBIT_FFI_EXPORT
int64_t mturso_stmt_tail(mturso_stmt_t *stmt) {
  return stmt != NULL ? stmt->tail : 0;
}

MOONBIT_FFI_EXPORT
int64_t mturso_stmt_column_count(mturso_stmt_t *stmt) {
  return stmt != NULL && stmt->stmt != NULL
             ? turso_statement_column_count(stmt->stmt)
             : 0;
}

static void stmt_bind_result(turso_status_code_t status) {
  if (status != TURSO_OK) {
    mturso_set_err_kind("failed to bind parameter", MTURSO_ERR_QUERY);
  }
}

static int stmt_ready(mturso_stmt_t *stmt) {
  if (stmt == NULL || stmt->stmt == NULL) {
    mturso_set_err("statement is not open");
    return 0;
  }
  return 1;
}

MOONBIT_FFI_EXPORT
void mturso_stmt_bind_null(mturso_stmt_t *stmt, int32_t pos) {
  mturso_clear_err();
  if (!stmt_ready(stmt)) {
    return;
  }
  stmt_bind_result(
      turso_statement_bind_positional_null(stmt->stmt, (size_t)pos));
}

MOONBIT_FFI_EXPORT
void mturso_stmt_bind_int(mturso_stmt_t *stmt, int32_t pos, int64_t value) {
  mturso_clear_err();
  if (!stmt_ready(stmt)) {
    return;
  }
  stmt_bind_result(turso_statement_bind_positional_int(stmt->stmt, (size_t)pos,
                                                       value));
}

MOONBIT_FFI_EXPORT
void mturso_stmt_bind_double(mturso_stmt_t *stmt, int32_t pos, double value) {
  mturso_clear_err();
  if (!stmt_ready(stmt)) {
    return;
  }
  stmt_bind_result(turso_statement_bind_positional_double(stmt->stmt, (size_t)pos,
                                                          value));
}

MOONBIT_FFI_EXPORT
void mturso_stmt_bind_text(mturso_stmt_t *stmt, int32_t pos,
                           moonbit_bytes_t value) {
  mturso_clear_err();
  if (!stmt_ready(stmt)) {
    return;
  }
  stmt_bind_result(turso_statement_bind_positional_text(
      stmt->stmt, (size_t)pos, (const char *)value,
      (size_t)Moonbit_array_length(value)));
}

MOONBIT_FFI_EXPORT
void mturso_stmt_bind_blob(mturso_stmt_t *stmt, int32_t pos,
                           moonbit_bytes_t value) {
  mturso_clear_err();
  if (!stmt_ready(stmt)) {
    return;
  }
  stmt_bind_result(turso_statement_bind_positional_blob(
      stmt->stmt, (size_t)pos, (const char *)value,
      (size_t)Moonbit_array_length(value)));
}

static mturso_fd_t submit_stmt_job(mturso_conn_t *conn, mturso_stmt_t *stmt,
                                   int job_kind) {
  mturso_clear_err();
  if (stmt == NULL || stmt->stmt == NULL) {
    mturso_set_err("statement is not open");
    return MTURSO_INVALID_FD;
  }

  mturso_fd_t fds[2];
  if (mturso_pipe_create(fds) != 0) {
    mturso_set_err("failed to create result channel");
    return MTURSO_INVALID_FD;
  }
  if (mturso_submit_job(conn, stmt->stmt, fds[1], job_kind) != 0) {
    mturso_fd_close(fds[0]);
    mturso_fd_close(fds[1]);
    return MTURSO_INVALID_FD;
  }
  return fds[0];
}

MOONBIT_FFI_EXPORT
mturso_fd_t mturso_submit_stmt_rows(mturso_conn_t *conn, mturso_stmt_t *stmt) {
  return submit_stmt_job(conn, stmt, MTURSO_JOB_ROWS);
}

MOONBIT_FFI_EXPORT
mturso_fd_t mturso_submit_stmt_execute(mturso_conn_t *conn,
                                       mturso_stmt_t *stmt) {
  return submit_stmt_job(conn, stmt, MTURSO_JOB_EXECUTE);
}
