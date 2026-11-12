#ifndef TURSO_SYNC_H
#define TURSO_SYNC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "turso.h"

typedef enum {
  TURSO_SYNC_IO_NONE = 0,
  TURSO_SYNC_IO_HTTP = 1,
  TURSO_SYNC_IO_FULL_READ = 2,
  TURSO_SYNC_IO_FULL_WRITE = 3,
} turso_sync_io_request_type_t;

typedef struct {
  turso_slice_ref_t url;
  turso_slice_ref_t method;
  turso_slice_ref_t path;
  turso_slice_ref_t body;
  int32_t headers;
} turso_sync_io_http_request_t;

typedef struct {
  turso_slice_ref_t key;
  turso_slice_ref_t value;
} turso_sync_io_http_header_t;

typedef struct {
  turso_slice_ref_t path;
} turso_sync_io_full_read_request_t;

typedef struct {
  turso_slice_ref_t path;
  turso_slice_ref_t content;
} turso_sync_io_full_write_request_t;

typedef enum {
  TURSO_ASYNC_RESULT_NONE = 0,
  TURSO_ASYNC_RESULT_CONNECTION = 1,
  TURSO_ASYNC_RESULT_CHANGES = 2,
  TURSO_ASYNC_RESULT_STATS = 3,
} turso_sync_operation_result_type_t;

typedef struct turso_sync_changes turso_sync_changes_t;

typedef struct {
  int64_t cdc_operations;
  int64_t main_wal_size;
  int64_t revert_wal_size;
  int64_t last_pull_unix_time;
  int64_t last_push_unix_time;
  int64_t network_sent_bytes;
  int64_t network_received_bytes;
  turso_slice_ref_t revision;
} turso_sync_stats_t;

typedef struct {
  const char *path;
  const char *remote_url;
  const char *client_name;
  int32_t long_poll_timeout_ms;
  bool bootstrap_if_empty;
  int32_t reserved_bytes;
  int32_t partial_bootstrap_strategy_prefix;
  const char *partial_bootstrap_strategy_query;
  size_t partial_bootstrap_segment_size;
  bool partial_bootstrap_prefetch;
  const char *remote_encryption_key;
  const char *remote_encryption_cipher;
  size_t push_operations_threshold;
  size_t pull_bytes_threshold;
  bool logical_mvcc_pull;
} turso_sync_database_config_t;

typedef struct turso_sync_database turso_sync_database_t;
typedef struct turso_sync_operation turso_sync_operation_t;
typedef struct turso_sync_io_item turso_sync_io_item_t;

turso_status_code_t turso_sync_database_new(
    const turso_database_config_t *db_config,
    const turso_sync_database_config_t *sync_config,
    const turso_sync_database_t **database, const char **error_opt_out);

turso_status_code_t turso_sync_database_open(
    const turso_sync_database_t *self,
    const turso_sync_operation_t **operation, const char **error_opt_out);

turso_status_code_t turso_sync_database_create(
    const turso_sync_database_t *self,
    const turso_sync_operation_t **operation, const char **error_opt_out);

turso_status_code_t turso_sync_database_connect(
    const turso_sync_database_t *self,
    const turso_sync_operation_t **operation, const char **error_opt_out);

turso_status_code_t turso_sync_database_stats(
    const turso_sync_database_t *self,
    const turso_sync_operation_t **operation, const char **error_opt_out);

turso_status_code_t turso_sync_database_checkpoint(
    const turso_sync_database_t *self,
    const turso_sync_operation_t **operation, const char **error_opt_out);

turso_status_code_t turso_sync_database_push_changes(
    const turso_sync_database_t *self,
    const turso_sync_operation_t **operation, const char **error_opt_out);

turso_status_code_t turso_sync_database_wait_changes(
    const turso_sync_database_t *self,
    const turso_sync_operation_t **operation, const char **error_opt_out);

turso_status_code_t turso_sync_database_apply_changes(
    const turso_sync_database_t *self, const turso_sync_changes_t *changes,
    const turso_sync_operation_t **operation, const char **error_opt_out);

turso_status_code_t turso_sync_operation_resume(
    const turso_sync_operation_t *self, const char **error_opt_out);

turso_sync_operation_result_type_t turso_sync_operation_result_kind(
    const turso_sync_operation_t *self);

turso_status_code_t turso_sync_operation_result_extract_connection(
    const turso_sync_operation_t *self,
    const turso_connection_t **connection);

turso_status_code_t turso_sync_operation_result_extract_changes(
    const turso_sync_operation_t *self,
    const turso_sync_changes_t **changes);

turso_status_code_t turso_sync_operation_result_extract_stats(
    const turso_sync_operation_t *self, turso_sync_stats_t *stats);

turso_status_code_t turso_sync_database_io_take_item(
    const turso_sync_database_t *self,
    const turso_sync_io_item_t **item, const char **error_opt_out);

turso_status_code_t turso_sync_database_io_step_callbacks(
    const turso_sync_database_t *self, const char **error_opt_out);

turso_sync_io_request_type_t turso_sync_database_io_request_kind(
    const turso_sync_io_item_t *self);

turso_status_code_t turso_sync_database_io_request_http(
    const turso_sync_io_item_t *self, turso_sync_io_http_request_t *request);

turso_status_code_t turso_sync_database_io_request_http_header(
    const turso_sync_io_item_t *self, size_t index,
    turso_sync_io_http_header_t *header);

turso_status_code_t turso_sync_database_io_request_full_read(
    const turso_sync_io_item_t *self,
    turso_sync_io_full_read_request_t *request);

turso_status_code_t turso_sync_database_io_request_full_write(
    const turso_sync_io_item_t *self,
    turso_sync_io_full_write_request_t *request);

turso_status_code_t turso_sync_database_io_poison(
    const turso_sync_io_item_t *self, turso_slice_ref_t *error);

turso_status_code_t turso_sync_database_io_status(
    const turso_sync_io_item_t *self, int32_t status);

turso_status_code_t turso_sync_database_io_push_buffer(
    const turso_sync_io_item_t *self, turso_slice_ref_t *buffer);

turso_status_code_t turso_sync_database_io_done(
    const turso_sync_io_item_t *self);

void turso_sync_database_deinit(const turso_sync_database_t *self);
void turso_sync_operation_deinit(const turso_sync_operation_t *self);
void turso_sync_database_io_item_deinit(const turso_sync_io_item_t *self);
void turso_sync_changes_deinit(const turso_sync_changes_t *self);

#endif
