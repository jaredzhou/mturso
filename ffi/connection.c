#include <stdio.h>
#include <string.h>

#include "mturso_internal.h"

typedef struct {
  const turso_database_t *db;
} mturso_db_t;

struct mturso_conn {
  turso_connection_t *conn;
  const turso_sync_database_t *sync_db;

  mturso_thread_t worker;
  int worker_started;
  mturso_mutex_t mu;
  mturso_cond_t cv;
  int has_job;
  int shutdown;
  mturso_fd_t stream_fd;
  turso_statement_t *job_stmt;
  int busy;
  int sync_mode;
  int waiting_for_sync_io;
  int sync_io_resume;
};

static void set_errbuf(char *buf, size_t len, const char *msg) {
  snprintf(buf, len, "%s", msg != NULL ? msg : "unknown error");
}

int mturso_step_to_done(turso_statement_t *stmt, const char **err, int *out_kind) {
  for (;;) {
    turso_status_code_t status = turso_statement_step(stmt, err);
    if (status == TURSO_ROW) {
      continue;
    }
    if (status == TURSO_IO) {
      if (turso_statement_run_io(stmt, err) != TURSO_OK) {
        return -1;
      }
      continue;
    }
    if (status == TURSO_DONE) {
      return 0;
    }
    if (out_kind != NULL) {
      *out_kind = mturso_kind_from_status(status);
    }
    return -1;
  }
}

static int64_t do_exec(turso_connection_t *conn, const char *sql, char *errbuf,
                       size_t errlen, int *out_kind) {
  const char *err = NULL;
  turso_statement_t *stmt = NULL;
  turso_status_code_t status =
      turso_connection_prepare_single(conn, sql, &stmt, &err);
  if (status != TURSO_OK) {
    if (out_kind != NULL) {
      *out_kind = mturso_kind_from_status(status);
    }
    set_errbuf(errbuf, errlen, err);
    return -1;
  }
  int rc = mturso_step_to_done(stmt, &err, out_kind);
  int64_t changes = turso_statement_n_change(stmt);
  turso_statement_deinit(stmt);
  if (rc != 0) {
    set_errbuf(errbuf, errlen, err);
    return -1;
  }
  return changes;
}

static turso_value_t turso_sleep_scalar(
    uintptr_t context, int32_t argc, const turso_value_t *argv,
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
#if defined(_WIN32)
    Sleep((DWORD)ms);
#else
    usleep((useconds_t)(ms * 1000));
#endif
  }
  turso_value_t out = {0};
  out.value_type = TURSO_EXTENSION_VALUE_INTEGER;
  out.value.int_value = ms;
  return out;
}

static void register_test_functions(turso_connection_t *conn) {
  const char *err = NULL;
  turso_connection_register_scalar_function(
      conn, "turso_sleep", 1, false, 0, turso_sleep_scalar, NULL, NULL, &err);
}

static void db_finalize(void *self) {
  mturso_db_t *db = (mturso_db_t *)self;
  if (db->db != NULL) {
    turso_database_deinit(db->db);
    db->db = NULL;
  }
}

MOONBIT_FFI_EXPORT
mturso_db_t *mturso_db_open(moonbit_bytes_t path) {
  mturso_clear_err();
  mturso_ensure_setup();

  mturso_db_t *handle =
      (mturso_db_t *)moonbit_make_external_object(db_finalize, sizeof(mturso_db_t));
  memset(handle, 0, sizeof(mturso_db_t));
  if (!mturso_setup_ready()) {
    if (!mturso_has_err()) {
      mturso_set_err("turso_setup failed");
    }
    return handle;
  }

  turso_database_config_t config = {0};
  config.path = (const char *)path;
  config.async_io = 0;

  const char *err = NULL;
  if (turso_database_new(&config, &handle->db, &err) != TURSO_OK) {
    mturso_set_err(err);
    return handle;
  }
  if (turso_database_open(handle->db, &err) != TURSO_OK) {
    mturso_set_err(err);
  }
  return handle;
}

MOONBIT_FFI_EXPORT
void mturso_db_close(mturso_db_t *db) {
  if (db == NULL || db->db == NULL) {
    return;
  }
  turso_database_deinit(db->db);
  db->db = NULL;
}

#if defined(_WIN32)
static unsigned __stdcall conn_worker(void *arg)
#else
static void *conn_worker(void *arg)
#endif
{
  mturso_conn_t *handle = (mturso_conn_t *)arg;
  for (;;) {
    mturso_mutex_lock(&handle->mu);
    while (!handle->has_job && !handle->shutdown) {
      mturso_cond_wait(&handle->cv, &handle->mu);
    }
    if (handle->shutdown && !handle->has_job) {
      mturso_mutex_unlock(&handle->mu);
      break;
    }

    turso_statement_t *stmt = handle->job_stmt;
    mturso_fd_t fd = handle->stream_fd;
    handle->job_stmt = NULL;
    handle->stream_fd = MTURSO_INVALID_FD;
    handle->has_job = 0;
    mturso_mutex_unlock(&handle->mu);

    if (stmt != NULL) {
      mturso_stream_stmt_rows(handle, stmt, fd);
    } else {
      mturso_send_error_frame(fd, "connection job has no statement",
                              MTURSO_ERR_CONNECTION);
    }
    mturso_fd_close(fd);

    mturso_mutex_lock(&handle->mu);
    handle->busy = 0;
    mturso_cond_broadcast(&handle->cv);
    mturso_mutex_unlock(&handle->mu);
  }
#if defined(_WIN32)
  return 0;
#else
  return NULL;
#endif
}

static void conn_stop_worker(mturso_conn_t *conn) {
  if (conn->worker_started) {
    mturso_mutex_lock(&conn->mu);
    conn->shutdown = 1;
    conn->sync_io_resume = 1;
    mturso_cond_broadcast(&conn->cv);
    mturso_mutex_unlock(&conn->mu);
    mturso_thread_join(conn->worker);
    conn->worker_started = 0;
  }
}

static void conn_finalize(void *self) {
  mturso_conn_t *handle = (mturso_conn_t *)self;
  conn_stop_worker(handle);
  if (handle->conn != NULL) {
    turso_connection_deinit(handle->conn);
    handle->conn = NULL;
  }
  mturso_mutex_destroy(&handle->mu);
  mturso_cond_destroy(&handle->cv);
}

MOONBIT_FFI_EXPORT
mturso_conn_t *mturso_db_connect(mturso_db_t *db) {
  mturso_clear_err();
  mturso_conn_t *handle = (mturso_conn_t *)moonbit_make_external_object(
      conn_finalize, sizeof(mturso_conn_t));
  memset(handle, 0, sizeof(mturso_conn_t));
  handle->stream_fd = MTURSO_INVALID_FD;
  mturso_mutex_init(&handle->mu);
  mturso_cond_init(&handle->cv);

  if (db == NULL || db->db == NULL) {
    mturso_set_err("database is not open");
    return handle;
  }
  const char *err = NULL;
  if (turso_database_connect(db->db, &handle->conn, &err) != TURSO_OK) {
    mturso_set_err(err);
    return handle;
  }
  register_test_functions(handle->conn);

  if (mturso_thread_start(&handle->worker, conn_worker, handle) == 0) {
    handle->worker_started = 1;
  } else {
    mturso_set_err("failed to start worker thread");
  }
  return handle;
}

mturso_conn_t *mturso_conn_adopt(turso_connection_t *conn,
                                 const turso_sync_database_t *sync_db) {
  mturso_conn_t *handle = (mturso_conn_t *)moonbit_make_external_object(
      conn_finalize, sizeof(mturso_conn_t));
  memset(handle, 0, sizeof(mturso_conn_t));
  handle->stream_fd = MTURSO_INVALID_FD;
  handle->conn = conn;
  handle->sync_db = sync_db;
  handle->sync_mode = sync_db != NULL ? 1 : 0;
  mturso_mutex_init(&handle->mu);
  mturso_cond_init(&handle->cv);
  if (handle->conn == NULL) {
    return handle;
  }
  register_test_functions(handle->conn);
  if (mturso_thread_start(&handle->worker, conn_worker, handle) == 0) {
    handle->worker_started = 1;
  } else {
    mturso_set_err("failed to start worker thread");
  }
  return handle;
}

MOONBIT_FFI_EXPORT
void mturso_conn_close(mturso_conn_t *conn) {
  if (conn == NULL) {
    return;
  }
  conn_stop_worker(conn);
  if (conn->conn != NULL) {
    turso_connection_deinit(conn->conn);
    conn->conn = NULL;
  }
}

turso_connection_t *mturso_conn_raw(mturso_conn_t *conn) {
  return conn != NULL ? conn->conn : NULL;
}

MOONBIT_FFI_EXPORT
int64_t mturso_conn_last_insert_rowid(mturso_conn_t *conn) {
  mturso_clear_err();
  if (conn == NULL || conn->conn == NULL) {
    mturso_set_err("connection is not open");
    return 0;
  }
  return turso_connection_last_insert_rowid(conn->conn);
}

MOONBIT_FFI_EXPORT
int32_t mturso_conn_get_autocommit(mturso_conn_t *conn) {
  mturso_clear_err();
  if (conn == NULL || conn->conn == NULL) {
    mturso_set_err("connection is not open");
    return 0;
  }
  return turso_connection_get_autocommit(conn->conn) ? 1 : 0;
}

MOONBIT_FFI_EXPORT
int64_t mturso_conn_exec(mturso_conn_t *conn, moonbit_bytes_t sql) {
  mturso_clear_err();
  if (conn == NULL || conn->conn == NULL) {
    mturso_set_err("connection is not open");
    return -1;
  }
  if (conn->sync_mode) {
    mturso_set_err_kind("sync connections require the async query API",
                        MTURSO_ERR_CONNECTION);
    return -1;
  }
  char errbuf[1024] = {0};
  int kind = MTURSO_ERR_NONE;
  int64_t changes =
      do_exec(conn->conn, (const char *)sql, errbuf, sizeof(errbuf), &kind);
  if (changes < 0) {
    mturso_set_err_kind(errbuf, kind);
  }
  return changes;
}

int mturso_submit_job(mturso_conn_t *conn, turso_statement_t *stmt,
                      mturso_fd_t stream_fd) {
  if (conn == NULL || conn->conn == NULL) {
    mturso_set_err("connection is not open");
    return -1;
  }
  if (!conn->worker_started) {
    mturso_set_err("worker thread is not running");
    return -1;
  }

  mturso_mutex_lock(&conn->mu);
  if (conn->has_job || conn->busy) {
    mturso_mutex_unlock(&conn->mu);
    mturso_set_err("a job is already in flight on this connection");
    return -1;
  }
  conn->stream_fd = stream_fd;
  conn->job_stmt = stmt;
  conn->busy = 1;
  conn->has_job = 1;
  mturso_cond_signal(&conn->cv);
  mturso_mutex_unlock(&conn->mu);
  return 0;
}

MOONBIT_FFI_EXPORT
void mturso_conn_wait_job(mturso_conn_t *conn) {
  if (conn == NULL) {
    return;
  }
  mturso_mutex_lock(&conn->mu);
  while (conn->busy) {
    mturso_cond_wait(&conn->cv, &conn->mu);
  }
  mturso_mutex_unlock(&conn->mu);
}

int mturso_conn_is_sync(mturso_conn_t *conn) {
  return conn != NULL && conn->sync_mode;
}

void mturso_conn_prepare_sync_io(mturso_conn_t *conn) {
  mturso_mutex_lock(&conn->mu);
  conn->waiting_for_sync_io = 1;
  conn->sync_io_resume = 0;
  mturso_mutex_unlock(&conn->mu);
}

void mturso_conn_wait_for_sync_io(mturso_conn_t *conn) {
  mturso_mutex_lock(&conn->mu);
  while (!conn->sync_io_resume && !conn->shutdown) {
    mturso_cond_wait(&conn->cv, &conn->mu);
  }
  conn->waiting_for_sync_io = 0;
  mturso_mutex_unlock(&conn->mu);
}

void mturso_conn_resume_sync_io(mturso_conn_t *conn) {
  if (conn == NULL) {
    return;
  }
  mturso_mutex_lock(&conn->mu);
  conn->sync_io_resume = 1;
  mturso_cond_broadcast(&conn->cv);
  mturso_mutex_unlock(&conn->mu);
}
