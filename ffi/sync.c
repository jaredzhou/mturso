#include <stdio.h>
#include <string.h>

#include "mturso_internal.h"

struct mturso_sync_db {
  const turso_sync_database_t *db;
};

struct mturso_sync_op {
  const turso_sync_operation_t *op;
};

struct mturso_sync_io {
  const turso_sync_io_item_t *item;
};

static int sync_error_kind(turso_status_code_t status) {
  switch (status) {
    case TURSO_BUSY:
      return MTURSO_ERR_SYNC_REMOTE_BUSY;
    case TURSO_BUSY_SNAPSHOT:
      return MTURSO_ERR_SYNC_REMOTE_CONFLICT;
    case TURSO_MISUSE:
      return MTURSO_ERR_SYNC_PROTOCOL;
    default:
      return MTURSO_ERR_SYNC_INTERNAL;
  }
}

static void sync_set_call_error(turso_status_code_t status, const char *error) {
  const char *message =
      error != NULL && error[0] != '\0' ? error : "sync engine operation failed";
  mturso_set_err_kind(message, sync_error_kind(status));
  if (error != NULL) {
    turso_str_deinit(error);
  }
}

static void sync_set_result_error(turso_status_code_t status,
                                  const char *operation) {
  char message[256];
  snprintf(message, sizeof(message), "%s failed with status %d", operation,
           (int)status);
  mturso_set_err_kind(message, sync_error_kind(status));
}

static void sync_db_finalize(void *self) {
  mturso_sync_db_t *handle = (mturso_sync_db_t *)self;
  if (handle->db != NULL) {
    turso_sync_database_deinit(handle->db);
    handle->db = NULL;
  }
}

static void sync_op_finalize(void *self) {
  mturso_sync_op_t *handle = (mturso_sync_op_t *)self;
  if (handle->op != NULL) {
    turso_sync_operation_deinit(handle->op);
    handle->op = NULL;
  }
}

static void sync_io_finalize(void *self) {
  mturso_sync_io_t *handle = (mturso_sync_io_t *)self;
  if (handle->item != NULL) {
    turso_sync_database_io_item_deinit(handle->item);
    handle->item = NULL;
  }
}

static mturso_sync_db_t *sync_db_alloc(void) {
  mturso_sync_db_t *handle = (mturso_sync_db_t *)moonbit_make_external_object(
      sync_db_finalize, sizeof(mturso_sync_db_t));
  memset(handle, 0, sizeof(mturso_sync_db_t));
  return handle;
}

static mturso_sync_op_t *sync_op_alloc(void) {
  mturso_sync_op_t *handle = (mturso_sync_op_t *)moonbit_make_external_object(
      sync_op_finalize, sizeof(mturso_sync_op_t));
  memset(handle, 0, sizeof(mturso_sync_op_t));
  return handle;
}

static mturso_sync_io_t *sync_io_alloc(void) {
  mturso_sync_io_t *handle = (mturso_sync_io_t *)moonbit_make_external_object(
      sync_io_finalize, sizeof(mturso_sync_io_t));
  memset(handle, 0, sizeof(mturso_sync_io_t));
  return handle;
}

static const turso_sync_database_t *sync_db_raw(mturso_sync_db_t *db) {
  return db != NULL ? db->db : NULL;
}

static const turso_sync_operation_t *sync_op_raw(mturso_sync_op_t *op) {
  return op != NULL ? op->op : NULL;
}

static const turso_sync_io_item_t *sync_io_raw(mturso_sync_io_t *item) {
  return item != NULL ? item->item : NULL;
}

MOONBIT_FFI_EXPORT
mturso_sync_db_t *mturso_sync_db_new(moonbit_bytes_t path,
                                     moonbit_bytes_t remote_url,
                                     moonbit_bytes_t client_name,
                                     int32_t long_poll_timeout_ms,
                                     int32_t bootstrap_if_empty) {
  mturso_clear_err();
  mturso_ensure_setup();
  mturso_sync_db_t *handle = sync_db_alloc();
  if (!mturso_setup_ready()) {
    if (!mturso_has_err()) {
      mturso_set_err("turso_setup failed");
    }
    return handle;
  }

  turso_database_config_t db_config = {0};
  db_config.path = (const char *)path;
  db_config.async_io = 1;

  turso_sync_database_config_t sync_config = {0};
  sync_config.path = (const char *)path;
  sync_config.remote_url = (const char *)remote_url;
  sync_config.client_name = (const char *)client_name;
  sync_config.long_poll_timeout_ms = long_poll_timeout_ms;
  sync_config.bootstrap_if_empty = bootstrap_if_empty != 0;

  const char *error = NULL;
  turso_status_code_t status = turso_sync_database_new(
      &db_config, &sync_config, &handle->db, &error);
  if (status != TURSO_OK) {
    sync_set_call_error(status, error);
  }
  return handle;
}

static mturso_sync_op_t *sync_db_start_operation(
    mturso_sync_db_t *db,
    turso_status_code_t (*start)(const turso_sync_database_t *,
                                 const turso_sync_operation_t **,
                                 const char **)) {
  mturso_clear_err();
  mturso_sync_op_t *handle = sync_op_alloc();
  const turso_sync_database_t *raw = sync_db_raw(db);
  if (raw == NULL) {
    mturso_set_err_kind("sync database is not open",
                        MTURSO_ERR_SYNC_INTERNAL);
    return handle;
  }
  const char *error = NULL;
  turso_status_code_t status = start(raw, &handle->op, &error);
  if (status != TURSO_OK) {
    sync_set_call_error(status, error);
  }
  return handle;
}

MOONBIT_FFI_EXPORT
mturso_sync_op_t *mturso_sync_db_create(mturso_sync_db_t *db) {
  return sync_db_start_operation(db, turso_sync_database_create);
}

MOONBIT_FFI_EXPORT
mturso_sync_op_t *mturso_sync_db_connect(mturso_sync_db_t *db) {
  return sync_db_start_operation(db, turso_sync_database_connect);
}

MOONBIT_FFI_EXPORT
int32_t mturso_sync_op_resume(mturso_sync_op_t *op) {
  mturso_clear_err();
  const turso_sync_operation_t *raw = sync_op_raw(op);
  if (raw == NULL) {
    mturso_set_err_kind("sync operation is not open",
                        MTURSO_ERR_SYNC_INTERNAL);
    return TURSO_ERROR;
  }
  const char *error = NULL;
  turso_status_code_t status = turso_sync_operation_resume(raw, &error);
  if (status != TURSO_OK && status != TURSO_IO && status != TURSO_DONE) {
    sync_set_call_error(status, error);
  }
  return (int32_t)status;
}

MOONBIT_FFI_EXPORT
int32_t mturso_sync_op_result_kind(mturso_sync_op_t *op) {
  const turso_sync_operation_t *raw = sync_op_raw(op);
  return raw != NULL ? (int32_t)turso_sync_operation_result_kind(raw) : 0;
}

MOONBIT_FFI_EXPORT
mturso_conn_t *mturso_sync_op_extract_connection(mturso_sync_op_t *op,
                                                 mturso_sync_db_t *db) {
  mturso_clear_err();
  const turso_sync_operation_t *raw_op = sync_op_raw(op);
  const turso_sync_database_t *raw_db = sync_db_raw(db);
  const turso_connection_t *raw_conn = NULL;
  if (raw_op == NULL || raw_db == NULL) {
    mturso_set_err_kind("sync operation or database is not open",
                        MTURSO_ERR_SYNC_INTERNAL);
    return mturso_conn_adopt(NULL, raw_db);
  }
  turso_status_code_t status =
      turso_sync_operation_result_extract_connection(raw_op, &raw_conn);
  if (status != TURSO_OK || raw_conn == NULL) {
    sync_set_result_error(status, "extract sync connection");
    return mturso_conn_adopt(NULL, raw_db);
  }
  return mturso_conn_adopt((turso_connection_t *)raw_conn, raw_db);
}

MOONBIT_FFI_EXPORT
void mturso_sync_db_close(mturso_sync_db_t *db) {
  if (db == NULL || db->db == NULL) {
    return;
  }
  turso_sync_database_deinit(db->db);
  db->db = NULL;
}

MOONBIT_FFI_EXPORT
void mturso_sync_op_close(mturso_sync_op_t *op) {
  if (op == NULL || op->op == NULL) {
    return;
  }
  turso_sync_operation_deinit(op->op);
  op->op = NULL;
}

MOONBIT_FFI_EXPORT
mturso_sync_io_t *mturso_sync_db_take_io(mturso_sync_db_t *db) {
  mturso_clear_err();
  mturso_sync_io_t *handle = sync_io_alloc();
  const turso_sync_database_t *raw = sync_db_raw(db);
  if (raw == NULL) {
    mturso_set_err_kind("sync database is not open",
                        MTURSO_ERR_SYNC_INTERNAL);
    return handle;
  }
  const char *error = NULL;
  turso_status_code_t status =
      turso_sync_database_io_take_item(raw, &handle->item, &error);
  if (status != TURSO_OK) {
    sync_set_call_error(status, error);
  }
  return handle;
}

MOONBIT_FFI_EXPORT
int32_t mturso_sync_io_is_null(mturso_sync_io_t *item) {
  return sync_io_raw(item) == NULL;
}

MOONBIT_FFI_EXPORT
int32_t mturso_sync_db_step_callbacks(mturso_sync_db_t *db) {
  mturso_clear_err();
  const turso_sync_database_t *raw = sync_db_raw(db);
  if (raw == NULL) {
    mturso_set_err_kind("sync database is not open",
                        MTURSO_ERR_SYNC_INTERNAL);
    return TURSO_ERROR;
  }
  const char *error = NULL;
  turso_status_code_t status =
      turso_sync_database_io_step_callbacks(raw, &error);
  if (status != TURSO_OK) {
    sync_set_call_error(status, error);
  }
  return (int32_t)status;
}

MOONBIT_FFI_EXPORT
int32_t mturso_sync_io_kind(mturso_sync_io_t *item) {
  const turso_sync_io_item_t *raw = sync_io_raw(item);
  return raw != NULL ? (int32_t)turso_sync_database_io_request_kind(raw) : 0;
}

static moonbit_bytes_t slice_bytes(turso_slice_ref_t slice) {
  return mturso_bytes_dup((const char *)slice.ptr, (int32_t)slice.len);
}

static int sync_io_ready(mturso_sync_io_t *item) {
  if (sync_io_raw(item) == NULL) {
    mturso_set_err_kind("sync IO item is not open",
                        MTURSO_ERR_SYNC_INTERNAL);
    return 0;
  }
  return 1;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_sync_io_http_url(mturso_sync_io_t *item) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return mturso_bytes_dup(NULL, 0);
  }
  turso_sync_io_http_request_t request = {0};
  turso_status_code_t status =
      turso_sync_database_io_request_http(sync_io_raw(item), &request);
  if (status != TURSO_OK) {
    sync_set_result_error(status, "read sync HTTP request");
    return mturso_bytes_dup(NULL, 0);
  }
  return slice_bytes(request.url);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_sync_io_http_method(mturso_sync_io_t *item) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return mturso_bytes_dup(NULL, 0);
  }
  turso_sync_io_http_request_t request = {0};
  turso_status_code_t status =
      turso_sync_database_io_request_http(sync_io_raw(item), &request);
  if (status != TURSO_OK) {
    sync_set_result_error(status, "read sync HTTP request");
    return mturso_bytes_dup(NULL, 0);
  }
  return slice_bytes(request.method);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_sync_io_http_path(mturso_sync_io_t *item) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return mturso_bytes_dup(NULL, 0);
  }
  turso_sync_io_http_request_t request = {0};
  turso_status_code_t status =
      turso_sync_database_io_request_http(sync_io_raw(item), &request);
  if (status != TURSO_OK) {
    sync_set_result_error(status, "read sync HTTP request");
    return mturso_bytes_dup(NULL, 0);
  }
  return slice_bytes(request.path);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_sync_io_http_body(mturso_sync_io_t *item) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return mturso_bytes_dup(NULL, 0);
  }
  turso_sync_io_http_request_t request = {0};
  turso_status_code_t status =
      turso_sync_database_io_request_http(sync_io_raw(item), &request);
  if (status != TURSO_OK) {
    sync_set_result_error(status, "read sync HTTP request");
    return mturso_bytes_dup(NULL, 0);
  }
  return slice_bytes(request.body);
}

MOONBIT_FFI_EXPORT
int32_t mturso_sync_io_http_header_count(mturso_sync_io_t *item) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return 0;
  }
  turso_sync_io_http_request_t request = {0};
  turso_status_code_t status =
      turso_sync_database_io_request_http(sync_io_raw(item), &request);
  if (status != TURSO_OK) {
    sync_set_result_error(status, "read sync HTTP request");
    return 0;
  }
  return request.headers;
}

static moonbit_bytes_t sync_io_header_part(mturso_sync_io_t *item,
                                           int32_t index, int key) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return mturso_bytes_dup(NULL, 0);
  }
  turso_sync_io_http_header_t header = {0};
  turso_status_code_t status = turso_sync_database_io_request_http_header(
      sync_io_raw(item), (size_t)index, &header);
  if (status != TURSO_OK) {
    sync_set_result_error(status, "read sync HTTP header");
    return mturso_bytes_dup(NULL, 0);
  }
  return slice_bytes(key ? header.key : header.value);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_sync_io_http_header_key(mturso_sync_io_t *item,
                                               int32_t index) {
  return sync_io_header_part(item, index, 1);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_sync_io_http_header_value(mturso_sync_io_t *item,
                                                 int32_t index) {
  return sync_io_header_part(item, index, 0);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_sync_io_full_read_path(mturso_sync_io_t *item) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return mturso_bytes_dup(NULL, 0);
  }
  turso_sync_io_full_read_request_t request = {0};
  turso_status_code_t status =
      turso_sync_database_io_request_full_read(sync_io_raw(item), &request);
  if (status != TURSO_OK) {
    sync_set_result_error(status, "read sync full-read request");
    return mturso_bytes_dup(NULL, 0);
  }
  return slice_bytes(request.path);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_sync_io_full_write_path(mturso_sync_io_t *item) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return mturso_bytes_dup(NULL, 0);
  }
  turso_sync_io_full_write_request_t request = {0};
  turso_status_code_t status =
      turso_sync_database_io_request_full_write(sync_io_raw(item), &request);
  if (status != TURSO_OK) {
    sync_set_result_error(status, "read sync full-write request");
    return mturso_bytes_dup(NULL, 0);
  }
  return slice_bytes(request.path);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_sync_io_full_write_content(mturso_sync_io_t *item) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return mturso_bytes_dup(NULL, 0);
  }
  turso_sync_io_full_write_request_t request = {0};
  turso_status_code_t status =
      turso_sync_database_io_request_full_write(sync_io_raw(item), &request);
  if (status != TURSO_OK) {
    sync_set_result_error(status, "read sync full-write request");
    return mturso_bytes_dup(NULL, 0);
  }
  return slice_bytes(request.content);
}

static int32_t sync_io_status_result(turso_status_code_t status,
                                     const char *operation) {
  if (status != TURSO_OK) {
    sync_set_result_error(status, operation);
  }
  return (int32_t)status;
}

MOONBIT_FFI_EXPORT
int32_t mturso_sync_io_status(mturso_sync_io_t *item, int32_t status_code) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return TURSO_ERROR;
  }
  return sync_io_status_result(
      turso_sync_database_io_status(sync_io_raw(item), status_code),
      "set sync HTTP status");
}

MOONBIT_FFI_EXPORT
int32_t mturso_sync_io_push_buffer(mturso_sync_io_t *item,
                                   moonbit_bytes_t buffer) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return TURSO_ERROR;
  }
  turso_slice_ref_t slice = {
      .ptr = buffer,
      .len = (size_t)Moonbit_array_length(buffer),
  };
  return sync_io_status_result(
      turso_sync_database_io_push_buffer(sync_io_raw(item), &slice),
      "push sync IO buffer");
}

MOONBIT_FFI_EXPORT
int32_t mturso_sync_io_poison(mturso_sync_io_t *item,
                              moonbit_bytes_t message) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return TURSO_ERROR;
  }
  turso_slice_ref_t slice = {
      .ptr = message,
      .len = (size_t)Moonbit_array_length(message),
  };
  return sync_io_status_result(
      turso_sync_database_io_poison(sync_io_raw(item), &slice),
      "poison sync IO request");
}

MOONBIT_FFI_EXPORT
int32_t mturso_sync_io_done(mturso_sync_io_t *item) {
  mturso_clear_err();
  if (!sync_io_ready(item)) {
    return TURSO_ERROR;
  }
  return sync_io_status_result(turso_sync_database_io_done(sync_io_raw(item)),
                               "complete sync IO request");
}

MOONBIT_FFI_EXPORT
void mturso_sync_io_close(mturso_sync_io_t *item) {
  if (item == NULL || item->item == NULL) {
    return;
  }
  turso_sync_database_io_item_deinit(item->item);
  item->item = NULL;
}
