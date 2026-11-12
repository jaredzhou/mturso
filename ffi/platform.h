#ifndef MTURSO_PLATFORM_H
#define MTURSO_PLATFORM_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <process.h>
#include <windows.h>

typedef HANDLE mturso_fd_t;
typedef HANDLE mturso_thread_t;
typedef CRITICAL_SECTION mturso_mutex_t;
typedef CONDITION_VARIABLE mturso_cond_t;
typedef unsigned(__stdcall *mturso_thread_fn_t)(void *);

#define MTURSO_INVALID_FD INVALID_HANDLE_VALUE

static inline int mturso_pipe_create(mturso_fd_t fds[2]) {
  SECURITY_ATTRIBUTES attrs = {sizeof(attrs), NULL, FALSE};
  return CreatePipe(&fds[0], &fds[1], &attrs, 0) ? 0 : -1;
}

static inline int mturso_fd_close(mturso_fd_t fd) {
  return CloseHandle(fd) ? 0 : -1;
}

static inline int mturso_fd_write(mturso_fd_t fd, const char *src, size_t len,
                                  size_t *written) {
  DWORD chunk = len > UINT32_MAX ? UINT32_MAX : (DWORD)len;
  DWORD count = 0;
  if (!WriteFile(fd, src, chunk, &count, NULL) || count == 0) {
    return -1;
  }
  *written = (size_t)count;
  return 0;
}

static inline int mturso_thread_start(mturso_thread_t *thread,
                                      mturso_thread_fn_t fn, void *arg) {
  uintptr_t handle = _beginthreadex(NULL, 0, fn, arg, 0, NULL);
  if (handle == 0) {
    return -1;
  }
  *thread = (HANDLE)handle;
  return 0;
}

static inline void mturso_thread_join(mturso_thread_t thread) {
  WaitForSingleObject(thread, INFINITE);
  CloseHandle(thread);
}

static inline void mturso_mutex_init(mturso_mutex_t *mutex) {
  InitializeCriticalSection(mutex);
}

static inline void mturso_mutex_destroy(mturso_mutex_t *mutex) {
  DeleteCriticalSection(mutex);
}

static inline void mturso_mutex_lock(mturso_mutex_t *mutex) {
  EnterCriticalSection(mutex);
}

static inline void mturso_mutex_unlock(mturso_mutex_t *mutex) {
  LeaveCriticalSection(mutex);
}

static inline void mturso_cond_init(mturso_cond_t *cond) {
  InitializeConditionVariable(cond);
}

static inline void mturso_cond_destroy(mturso_cond_t *cond) {
  (void)cond;
}

static inline void mturso_cond_wait(mturso_cond_t *cond,
                                    mturso_mutex_t *mutex) {
  SleepConditionVariableCS(cond, mutex, INFINITE);
}

static inline void mturso_cond_signal(mturso_cond_t *cond) {
  WakeConditionVariable(cond);
}

static inline void mturso_cond_broadcast(mturso_cond_t *cond) {
  WakeAllConditionVariable(cond);
}

#else

#include <pthread.h>
#include <unistd.h>

typedef int mturso_fd_t;
typedef pthread_t mturso_thread_t;
typedef pthread_mutex_t mturso_mutex_t;
typedef pthread_cond_t mturso_cond_t;
typedef void *(*mturso_thread_fn_t)(void *);

#define MTURSO_INVALID_FD (-1)

static inline int mturso_pipe_create(mturso_fd_t fds[2]) {
  return pipe(fds);
}

static inline int mturso_fd_close(mturso_fd_t fd) { return close(fd); }

static inline int mturso_fd_write(mturso_fd_t fd, const char *src, size_t len,
                                  size_t *written) {
  ssize_t count = write(fd, src, len);
  if (count <= 0) {
    return -1;
  }
  *written = (size_t)count;
  return 0;
}

static inline int mturso_thread_start(mturso_thread_t *thread,
                                      mturso_thread_fn_t fn, void *arg) {
  return pthread_create(thread, NULL, fn, arg);
}

static inline void mturso_thread_join(mturso_thread_t thread) {
  pthread_join(thread, NULL);
}

static inline void mturso_mutex_init(mturso_mutex_t *mutex) {
  pthread_mutex_init(mutex, NULL);
}

static inline void mturso_mutex_destroy(mturso_mutex_t *mutex) {
  pthread_mutex_destroy(mutex);
}

static inline void mturso_mutex_lock(mturso_mutex_t *mutex) {
  pthread_mutex_lock(mutex);
}

static inline void mturso_mutex_unlock(mturso_mutex_t *mutex) {
  pthread_mutex_unlock(mutex);
}

static inline void mturso_cond_init(mturso_cond_t *cond) {
  pthread_cond_init(cond, NULL);
}

static inline void mturso_cond_destroy(mturso_cond_t *cond) {
  pthread_cond_destroy(cond);
}

static inline void mturso_cond_wait(mturso_cond_t *cond,
                                    mturso_mutex_t *mutex) {
  pthread_cond_wait(cond, mutex);
}

static inline void mturso_cond_signal(mturso_cond_t *cond) {
  pthread_cond_signal(cond);
}

static inline void mturso_cond_broadcast(mturso_cond_t *cond) {
  pthread_cond_broadcast(cond);
}

#endif

#endif
