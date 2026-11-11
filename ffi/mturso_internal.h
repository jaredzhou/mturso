#ifndef MTURSO_INTERNAL_H
#define MTURSO_INTERNAL_H

#include <moonbit.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "turso.h"

enum {
  MTURSO_ERR_NONE = 0,
  MTURSO_ERR_QUERY = 1,
  MTURSO_ERR_BUSY = 2,
  MTURSO_ERR_CONFLICT = 3,
  MTURSO_ERR_CONNECTION = 4,
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

turso_connection_t *mturso_conn_raw(mturso_conn_t *conn);
int mturso_step_to_done(turso_statement_t *stmt, const char **err, int *out_kind);
void mturso_stream_stmt_rows(turso_statement_t *stmt, int fd);
void mturso_send_error_frame(int fd, const char *msg, int kind);
int mturso_submit_job(mturso_conn_t *conn, turso_statement_t *stmt, int stream_fd);

#endif
