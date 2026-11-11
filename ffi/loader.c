#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#define MTURSO_LOADER_IMPL
#include "mturso_internal.h"

#if defined(__APPLE__)
#define MTURSO_LIB_FILE "libturso_sync_sdk_kit.dylib"
#elif defined(_WIN32)
#define MTURSO_LIB_FILE "turso_sync_sdk_kit.dll"
#else
#define MTURSO_LIB_FILE "libturso_sync_sdk_kit.so"
#endif

turso_api_t mturso_api;

static void *g_lib = NULL;
static int g_setup_state = 0;
static char g_load_reason[1024];

static int try_load(const char *path) {
  dlerror();
  void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (handle == NULL) {
    const char *why = dlerror();
    snprintf(g_load_reason, sizeof(g_load_reason), "%s",
             why != NULL ? why : "unknown dlopen error");
    return -1;
  }
#define RESOLVE(field)                                                          \
  do {                                                                          \
    dlerror();                                                                  \
    *(void **)(&mturso_api.field) = dlsym(handle, #field);                      \
    if (mturso_api.field == NULL) {                                             \
      const char *why = dlerror();                                              \
      snprintf(g_load_reason, sizeof(g_load_reason), "missing symbol %s: %s",   \
               #field, why != NULL ? why : "unknown dlsym error");              \
      dlclose(handle);                                                          \
      return -1;                                                                \
    }                                                                           \
  } while (0)
  RESOLVE(turso_setup);
  RESOLVE(turso_database_new);
  RESOLVE(turso_database_open);
  RESOLVE(turso_database_connect);
  RESOLVE(turso_database_deinit);
  RESOLVE(turso_connection_deinit);
  RESOLVE(turso_connection_last_insert_rowid);
  RESOLVE(turso_connection_prepare_single);
  RESOLVE(turso_connection_prepare_first);
  RESOLVE(turso_connection_register_scalar_function);
  RESOLVE(turso_statement_bind_positional_null);
  RESOLVE(turso_statement_bind_positional_int);
  RESOLVE(turso_statement_bind_positional_double);
  RESOLVE(turso_statement_bind_positional_text);
  RESOLVE(turso_statement_bind_positional_blob);
  RESOLVE(turso_statement_column_count);
  RESOLVE(turso_statement_column_name);
  RESOLVE(turso_statement_column_decltype);
  RESOLVE(turso_statement_n_change);
  RESOLVE(turso_statement_row_value_kind);
  RESOLVE(turso_statement_row_value_int);
  RESOLVE(turso_statement_row_value_double);
  RESOLVE(turso_statement_row_value_bytes_ptr);
  RESOLVE(turso_statement_row_value_bytes_count);
  RESOLVE(turso_statement_step);
  RESOLVE(turso_statement_run_io);
  RESOLVE(turso_statement_deinit);
#undef RESOLVE
  g_lib = handle;
  g_load_reason[0] = '\0';
  return 0;
}

static const char *source_lib_path(char *buf, size_t len) {
  snprintf(buf, len, "%s", __FILE__);
  char *slash = strrchr(buf, '/');
  if (slash == NULL) {
    return NULL;
  }
  *slash = '\0';
  slash = strrchr(buf, '/');
  if (slash == NULL) {
    snprintf(buf, len, ".");
  } else {
    *slash = '\0';
  }
  size_t used = strlen(buf);
  if (used + sizeof("/libs/" MTURSO_LIB_FILE) > len) {
    return NULL;
  }
  snprintf(buf + used, len - used, "/libs/%s", MTURSO_LIB_FILE);
  return buf;
}

static int executable_path(char *buf, size_t len) {
#if defined(__APPLE__)
  uint32_t size = (uint32_t)len;
  if (_NSGetExecutablePath(buf, &size) != 0) {
    return -1;
  }
  char resolved[4096];
  if (realpath(buf, resolved) != NULL) {
    snprintf(buf, len, "%s", resolved);
  }
  return 0;
#elif defined(__linux__)
  ssize_t n = readlink("/proc/self/exe", buf, len - 1);
  if (n <= 0 || (size_t)n >= len) {
    return -1;
  }
  buf[n] = '\0';
  return 0;
#else
  (void)buf;
  (void)len;
  return -1;
#endif
}

static const char *exe_lib_path(char *buf, size_t len) {
  if (executable_path(buf, len) != 0) {
    return NULL;
  }
  char *slash = strrchr(buf, '/');
  if (slash == NULL) {
    return NULL;
  }
  *slash = '\0';
  snprintf(slash, (size_t)(len - (slash - buf)), "/libs/%s", MTURSO_LIB_FILE);
  return buf;
}

static int load_turso(void) {
  if (g_lib != NULL) {
    return 0;
  }

  const char *env = getenv("MTURSO_LIB_PATH");
  if (env != NULL && env[0] != '\0') {
    if (try_load(env) == 0) {
      return 0;
    }
    char msg[2048];
    snprintf(msg, sizeof(msg), "cannot load $MTURSO_LIB_PATH=%s: %s", env,
             g_load_reason);
    mturso_set_err(msg);
    return -1;
  }

  char source_path[4096];
  char exe_path[4096];
  const char *candidates[4];
  size_t count = 0;
  const char *source_libs = source_lib_path(source_path, sizeof(source_path));
  if (source_libs != NULL) {
    candidates[count++] = source_libs;
  }
  const char *exe_libs = exe_lib_path(exe_path, sizeof(exe_path));
  if (exe_libs != NULL) {
    candidates[count++] = exe_libs;
  }
  candidates[count++] = "./libs/" MTURSO_LIB_FILE;
  candidates[count++] = MTURSO_LIB_FILE;
  for (size_t i = 0; i < count; i++) {
    if (try_load(candidates[i]) == 0) {
      return 0;
    }
  }

  char msg[2048];
  snprintf(msg, sizeof(msg),
           "cannot load " MTURSO_LIB_FILE
           "; searched <mturso-source>/libs/, <exe>/libs/, ./libs/, and the "
           "system loader path; last error: %s",
           g_load_reason);
  mturso_set_err(msg);
  return -1;
}

void mturso_ensure_setup(void) {
  if (g_setup_state != 0) {
    return;
  }
  signal(SIGPIPE, SIG_IGN);
  if (load_turso() != 0) {
    g_setup_state = -1;
    return;
  }
  turso_config_t config = {0};
  const char *error = NULL;
  if (mturso_api.turso_setup(&config, &error) != TURSO_OK) {
    g_setup_state = -1;
    mturso_set_err(error);
    return;
  }
  g_setup_state = 1;
}

int mturso_setup_ready(void) { return g_setup_state == 1; }
