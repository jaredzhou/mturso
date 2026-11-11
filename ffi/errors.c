#include <stdio.h>
#include <string.h>

#include "mturso_internal.h"

static char g_err[2048];
static int g_kind = MTURSO_ERR_NONE;

void mturso_clear_err(void) {
  g_err[0] = '\0';
  g_kind = MTURSO_ERR_NONE;
}

void mturso_set_err_kind(const char *msg, int kind) {
  snprintf(g_err, sizeof(g_err), "%s", msg != NULL ? msg : "unknown error");
  g_kind = kind;
}

void mturso_set_err(const char *msg) {
  mturso_set_err_kind(msg, MTURSO_ERR_CONNECTION);
}

int mturso_has_err(void) { return g_err[0] != '\0'; }

int mturso_kind_from_status(turso_status_code_t status) {
  switch (status) {
    case TURSO_BUSY:
      return MTURSO_ERR_BUSY;
    case TURSO_BUSY_SNAPSHOT:
      return MTURSO_ERR_CONFLICT;
    default:
      return MTURSO_ERR_QUERY;
  }
}

moonbit_bytes_t mturso_bytes_dup(const char *src, int32_t len) {
  moonbit_bytes_t bytes = moonbit_make_bytes(len, 0);
  if (len > 0 && src != NULL) {
    memcpy(bytes, src, (size_t)len);
  }
  return bytes;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mturso_last_error(void) {
  return mturso_bytes_dup(g_err, (int32_t)strlen(g_err));
}

MOONBIT_FFI_EXPORT
int32_t mturso_last_error_kind(void) { return (int32_t)g_kind; }
