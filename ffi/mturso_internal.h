#ifndef MTURSO_INTERNAL_H
#define MTURSO_INTERNAL_H

#include <moonbit.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "platform.h"
#include "turso.h"
#include "turso_sync.h"

enum {
  MTURSO_ERR_NONE = 0,
  MTURSO_ERR_QUERY = 1,
  MTURSO_ERR_BUSY = 2,
  MTURSO_ERR_CONFLICT = 3,
  MTURSO_ERR_CONNECTION = 4,
  MTURSO_ERR_SYNC_NETWORK = 5,
  MTURSO_ERR_SYNC_AUTH = 6,
  MTURSO_ERR_SYNC_PROTOCOL = 7,
  MTURSO_ERR_SYNC_REMOTE_BUSY = 8,
  MTURSO_ERR_SYNC_REMOTE_CONFLICT = 9,
  MTURSO_ERR_SYNC_INTERNAL = 10,
};

typedef struct {
  turso_status_code_t (*turso_setup)(const turso_config_t *, const char **);
  turso_status_code_t (*turso_database_new)(const turso_database_config_t *,
                                            const turso_database_t **, const char **);
  turso_status_code_t (*turso_database_open)(const turso_database_t *, const char **);
  turso_status_code_t (*turso_database_connect)(const turso_database_t *,
                                                turso_connection_t **, const char **);
  void (*turso_database_deinit)(const turso_database_t *);
  void (*turso_connection_deinit)(const turso_connection_t *);
  int64_t (*turso_connection_last_insert_rowid)(const turso_connection_t *);
  bool (*turso_connection_get_autocommit)(const turso_connection_t *);
  turso_status_code_t (*turso_connection_prepare_single)(
      const turso_connection_t *, const char *, turso_statement_t **, const char **);
  turso_status_code_t (*turso_connection_prepare_first)(
      const turso_connection_t *, const char *, turso_statement_t **, size_t *,
      const char **);
  turso_status_code_t (*turso_connection_register_scalar_function)(
      const turso_connection_t *, const char *, int32_t, bool, uintptr_t,
      turso_scalar_function_t, turso_context_destructor_t,
      turso_value_destructor_t, const char **);
  turso_status_code_t (*turso_statement_bind_positional_null)(
      const turso_statement_t *, size_t);
  turso_status_code_t (*turso_statement_bind_positional_int)(
      const turso_statement_t *, size_t, int64_t);
  turso_status_code_t (*turso_statement_bind_positional_double)(
      const turso_statement_t *, size_t, double);
  turso_status_code_t (*turso_statement_bind_positional_text)(
      const turso_statement_t *, size_t, const char *, size_t);
  turso_status_code_t (*turso_statement_bind_positional_blob)(
      const turso_statement_t *, size_t, const char *, size_t);
  int64_t (*turso_statement_column_count)(const turso_statement_t *);
  const char *(*turso_statement_column_name)(const turso_statement_t *, size_t);
  const char *(*turso_statement_column_decltype)(const turso_statement_t *, size_t);
  int64_t (*turso_statement_n_change)(const turso_statement_t *);
  turso_type_t (*turso_statement_row_value_kind)(const turso_statement_t *, size_t);
  int64_t (*turso_statement_row_value_int)(const turso_statement_t *, size_t);
  double (*turso_statement_row_value_double)(const turso_statement_t *, size_t);
  const char *(*turso_statement_row_value_bytes_ptr)(const turso_statement_t *,
                                                     size_t);
  int64_t (*turso_statement_row_value_bytes_count)(const turso_statement_t *,
                                                   size_t);
  turso_status_code_t (*turso_statement_step)(const turso_statement_t *,
                                              const char **);
  turso_status_code_t (*turso_statement_run_io)(const turso_statement_t *,
                                                const char **);
  void (*turso_statement_deinit)(const turso_statement_t *);
  void (*turso_str_deinit)(const char *);

  turso_status_code_t (*turso_sync_database_new)(
      const turso_database_config_t *, const turso_sync_database_config_t *,
      const turso_sync_database_t **, const char **);
  turso_status_code_t (*turso_sync_database_open)(
      const turso_sync_database_t *, const turso_sync_operation_t **,
      const char **);
  turso_status_code_t (*turso_sync_database_create)(
      const turso_sync_database_t *, const turso_sync_operation_t **,
      const char **);
  turso_status_code_t (*turso_sync_database_connect)(
      const turso_sync_database_t *, const turso_sync_operation_t **,
      const char **);
  turso_status_code_t (*turso_sync_database_stats)(
      const turso_sync_database_t *, const turso_sync_operation_t **,
      const char **);
  turso_status_code_t (*turso_sync_database_checkpoint)(
      const turso_sync_database_t *, const turso_sync_operation_t **,
      const char **);
  turso_status_code_t (*turso_sync_database_push_changes)(
      const turso_sync_database_t *, const turso_sync_operation_t **,
      const char **);
  turso_status_code_t (*turso_sync_database_wait_changes)(
      const turso_sync_database_t *, const turso_sync_operation_t **,
      const char **);
  turso_status_code_t (*turso_sync_database_apply_changes)(
      const turso_sync_database_t *, const turso_sync_changes_t *,
      const turso_sync_operation_t **, const char **);
  turso_status_code_t (*turso_sync_operation_resume)(
      const turso_sync_operation_t *, const char **);
  turso_sync_operation_result_type_t (*turso_sync_operation_result_kind)(
      const turso_sync_operation_t *);
  turso_status_code_t (*turso_sync_operation_result_extract_connection)(
      const turso_sync_operation_t *, const turso_connection_t **);
  turso_status_code_t (*turso_sync_operation_result_extract_changes)(
      const turso_sync_operation_t *, const turso_sync_changes_t **);
  turso_status_code_t (*turso_sync_operation_result_extract_stats)(
      const turso_sync_operation_t *, turso_sync_stats_t *);
  turso_status_code_t (*turso_sync_database_io_take_item)(
      const turso_sync_database_t *, const turso_sync_io_item_t **,
      const char **);
  turso_status_code_t (*turso_sync_database_io_step_callbacks)(
      const turso_sync_database_t *, const char **);
  turso_sync_io_request_type_t (*turso_sync_database_io_request_kind)(
      const turso_sync_io_item_t *);
  turso_status_code_t (*turso_sync_database_io_request_http)(
      const turso_sync_io_item_t *, turso_sync_io_http_request_t *);
  turso_status_code_t (*turso_sync_database_io_request_http_header)(
      const turso_sync_io_item_t *, size_t, turso_sync_io_http_header_t *);
  turso_status_code_t (*turso_sync_database_io_request_full_read)(
      const turso_sync_io_item_t *, turso_sync_io_full_read_request_t *);
  turso_status_code_t (*turso_sync_database_io_request_full_write)(
      const turso_sync_io_item_t *, turso_sync_io_full_write_request_t *);
  turso_status_code_t (*turso_sync_database_io_poison)(
      const turso_sync_io_item_t *, turso_slice_ref_t *);
  turso_status_code_t (*turso_sync_database_io_status)(
      const turso_sync_io_item_t *, int32_t);
  turso_status_code_t (*turso_sync_database_io_push_buffer)(
      const turso_sync_io_item_t *, turso_slice_ref_t *);
  turso_status_code_t (*turso_sync_database_io_done)(
      const turso_sync_io_item_t *);
  void (*turso_sync_database_deinit)(const turso_sync_database_t *);
  void (*turso_sync_operation_deinit)(const turso_sync_operation_t *);
  void (*turso_sync_database_io_item_deinit)(const turso_sync_io_item_t *);
  void (*turso_sync_changes_deinit)(const turso_sync_changes_t *);
} turso_api_t;

extern turso_api_t mturso_api;

#ifndef MTURSO_LOADER_IMPL
#define turso_setup mturso_api.turso_setup
#define turso_database_new mturso_api.turso_database_new
#define turso_database_open mturso_api.turso_database_open
#define turso_database_connect mturso_api.turso_database_connect
#define turso_database_deinit mturso_api.turso_database_deinit
#define turso_connection_deinit mturso_api.turso_connection_deinit
#define turso_connection_last_insert_rowid mturso_api.turso_connection_last_insert_rowid
#define turso_connection_get_autocommit mturso_api.turso_connection_get_autocommit
#define turso_connection_prepare_single mturso_api.turso_connection_prepare_single
#define turso_connection_prepare_first mturso_api.turso_connection_prepare_first
#define turso_connection_register_scalar_function \
  mturso_api.turso_connection_register_scalar_function
#define turso_statement_bind_positional_null \
  mturso_api.turso_statement_bind_positional_null
#define turso_statement_bind_positional_int \
  mturso_api.turso_statement_bind_positional_int
#define turso_statement_bind_positional_double \
  mturso_api.turso_statement_bind_positional_double
#define turso_statement_bind_positional_text \
  mturso_api.turso_statement_bind_positional_text
#define turso_statement_bind_positional_blob \
  mturso_api.turso_statement_bind_positional_blob
#define turso_statement_column_count mturso_api.turso_statement_column_count
#define turso_statement_column_name mturso_api.turso_statement_column_name
#define turso_statement_column_decltype mturso_api.turso_statement_column_decltype
#define turso_statement_n_change mturso_api.turso_statement_n_change
#define turso_statement_row_value_kind mturso_api.turso_statement_row_value_kind
#define turso_statement_row_value_int mturso_api.turso_statement_row_value_int
#define turso_statement_row_value_double mturso_api.turso_statement_row_value_double
#define turso_statement_row_value_bytes_ptr \
  mturso_api.turso_statement_row_value_bytes_ptr
#define turso_statement_row_value_bytes_count \
  mturso_api.turso_statement_row_value_bytes_count
#define turso_statement_step mturso_api.turso_statement_step
#define turso_statement_run_io mturso_api.turso_statement_run_io
#define turso_statement_deinit mturso_api.turso_statement_deinit
#define turso_str_deinit mturso_api.turso_str_deinit
#define turso_sync_database_new mturso_api.turso_sync_database_new
#define turso_sync_database_open mturso_api.turso_sync_database_open
#define turso_sync_database_create mturso_api.turso_sync_database_create
#define turso_sync_database_connect mturso_api.turso_sync_database_connect
#define turso_sync_database_stats mturso_api.turso_sync_database_stats
#define turso_sync_database_checkpoint mturso_api.turso_sync_database_checkpoint
#define turso_sync_database_push_changes \
  mturso_api.turso_sync_database_push_changes
#define turso_sync_database_wait_changes \
  mturso_api.turso_sync_database_wait_changes
#define turso_sync_database_apply_changes \
  mturso_api.turso_sync_database_apply_changes
#define turso_sync_operation_resume mturso_api.turso_sync_operation_resume
#define turso_sync_operation_result_kind \
  mturso_api.turso_sync_operation_result_kind
#define turso_sync_operation_result_extract_connection \
  mturso_api.turso_sync_operation_result_extract_connection
#define turso_sync_operation_result_extract_changes \
  mturso_api.turso_sync_operation_result_extract_changes
#define turso_sync_operation_result_extract_stats \
  mturso_api.turso_sync_operation_result_extract_stats
#define turso_sync_database_io_take_item \
  mturso_api.turso_sync_database_io_take_item
#define turso_sync_database_io_step_callbacks \
  mturso_api.turso_sync_database_io_step_callbacks
#define turso_sync_database_io_request_kind \
  mturso_api.turso_sync_database_io_request_kind
#define turso_sync_database_io_request_http \
  mturso_api.turso_sync_database_io_request_http
#define turso_sync_database_io_request_http_header \
  mturso_api.turso_sync_database_io_request_http_header
#define turso_sync_database_io_request_full_read \
  mturso_api.turso_sync_database_io_request_full_read
#define turso_sync_database_io_request_full_write \
  mturso_api.turso_sync_database_io_request_full_write
#define turso_sync_database_io_poison mturso_api.turso_sync_database_io_poison
#define turso_sync_database_io_status mturso_api.turso_sync_database_io_status
#define turso_sync_database_io_push_buffer \
  mturso_api.turso_sync_database_io_push_buffer
#define turso_sync_database_io_done mturso_api.turso_sync_database_io_done
#define turso_sync_database_deinit mturso_api.turso_sync_database_deinit
#define turso_sync_operation_deinit mturso_api.turso_sync_operation_deinit
#define turso_sync_database_io_item_deinit \
  mturso_api.turso_sync_database_io_item_deinit
#define turso_sync_changes_deinit mturso_api.turso_sync_changes_deinit
#endif

void mturso_clear_err(void);
void mturso_set_err(const char *msg);
void mturso_set_err_kind(const char *msg, int kind);
int mturso_has_err(void);
int mturso_kind_from_status(turso_status_code_t status);
moonbit_bytes_t mturso_bytes_dup(const char *src, int32_t len);

void mturso_ensure_setup(void);
int mturso_setup_ready(void);

typedef struct mturso_conn mturso_conn_t;
typedef struct mturso_sync_db mturso_sync_db_t;
typedef struct mturso_sync_op mturso_sync_op_t;
typedef struct mturso_sync_io mturso_sync_io_t;
typedef struct mturso_sync_changes mturso_sync_changes_t;
typedef struct mturso_sync_stats mturso_sync_stats_t;

turso_connection_t *mturso_conn_raw(mturso_conn_t *conn);
mturso_conn_t *mturso_conn_adopt(turso_connection_t *conn,
                                 const turso_sync_database_t *sync_db);
int mturso_conn_is_sync(mturso_conn_t *conn);
void mturso_conn_prepare_sync_io(mturso_conn_t *conn);
void mturso_conn_wait_for_sync_io(mturso_conn_t *conn);
void mturso_conn_resume_sync_io(mturso_conn_t *conn);
int mturso_step_to_done(turso_statement_t *stmt, const char **err, int *out_kind);
void mturso_stream_stmt_rows(mturso_conn_t *conn, turso_statement_t *stmt,
                             mturso_fd_t fd);
void mturso_send_error_frame(mturso_fd_t fd, const char *msg, int kind);
int mturso_submit_job(mturso_conn_t *conn, turso_statement_t *stmt,
                      mturso_fd_t stream_fd);

#endif
