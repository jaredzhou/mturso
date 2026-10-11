// Turso C ABI 的最小骨架：每个连接一个工作线程 + 门铃 pipe。
//
// 验证两件事：
//   1. C 侧要写多少代码（这就是全部，约 120 行）；
//   2. 工作线程做阻塞调用时，事件循环线程（这里是心跳线程）不会被卡住。
//
// 用法见同目录 README.md
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "turso.h"

#define CONNS 2
#define HEARTBEAT_MS 20

static int g_bell_w = -1; // 门铃写端（工作线程做完就写 1 字节）

typedef struct {
  int id;
  const char *sql;
  int64_t result;
  int ok;
  pthread_mutex_t mu; // 结果槽的锁
} job_t;

// 敲门铃：必须在「结果已发布」之后再调用
static void ring(void) {
  char b = 1;
  ssize_t n = write(g_bell_w, &b, 1);
  (void)n;
}

// 每个连接一个工作线程；连接钉在这个线程上（actor 模型）
static void *worker(void *arg) {
  job_t *j = (job_t *)arg;
  const char *err = NULL;
  const turso_database_t *db = NULL;
  turso_connection_t *conn = NULL; // connect 的出参是非 const 指针
  turso_statement_t *stmt = NULL;

  turso_database_config_t dcfg = {0};
  dcfg.path = ":memory:";
  dcfg.async_io = 0; // 库自己推进 I/O —— 但只在【本线程】上

  if (turso_database_new(&dcfg, &db, &err) != TURSO_OK) goto fail;
  if (turso_database_open(db, &err) != TURSO_OK) goto fail;
  if (turso_database_connect(db, &conn, &err) != TURSO_OK) goto fail;
  if (turso_connection_prepare_single(conn, j->sql, &stmt, &err) != TURSO_OK) goto fail;

  for (;;) {
    turso_status_code_t st = turso_statement_step(stmt, &err);
    if (st == TURSO_ROW) {
      int64_t v = turso_statement_row_value_int(stmt, 0);
      pthread_mutex_lock(&j->mu);
      j->result = v;
      j->ok = 1;
      pthread_mutex_unlock(&j->mu);
    } else if (st == TURSO_DONE) {
      break;
    } else if (st == TURSO_IO) {
      if (turso_statement_run_io(stmt, &err) != TURSO_OK) goto fail;
    } else {
      goto fail;
    }
  }

  turso_statement_deinit(stmt);
  stmt = NULL;
  turso_connection_deinit(conn);
  conn = NULL;
  turso_database_deinit(db);
  db = NULL;
  ring(); // 先发布结果，再敲门铃
  return NULL;

fail:
  fprintf(stderr, "worker %d 失败: %s\n", j->id, err ? err : "unknown error");
  if (stmt) turso_statement_deinit(stmt);
  if (conn) turso_connection_deinit(conn);
  if (db) turso_database_deinit(db);
  ring();
  return NULL;
}

// 模拟「事件循环线程」：如果工作线程真的没阻塞主线程，它应该照常被调度
static void *heartbeat(void *arg) {
  (void)arg;
  for (int i = 0; i < 5; i++) {
    usleep(HEARTBEAT_MS * 1000);
    printf("[心跳] 事件循环线程仍在跑别的任务 #%d\n", i + 1);
    fflush(stdout);
  }
  return NULL;
}

int main(void) {
  const char *err = NULL;
  turso_config_t gcfg = {0};
  if (turso_setup(&gcfg, &err) != TURSO_OK) {
    fprintf(stderr, "setup 失败: %s\n", err);
    return 1;
  }

  int bell[2];
  if (pipe(bell) != 0) {
    perror("pipe");
    return 1;
  }
  g_bell_w = bell[1];

  job_t jobs[CONNS] = {
      {.id = 0, .sql = "select 6 * 7", .mu = PTHREAD_MUTEX_INITIALIZER},
      {.id = 1, .sql = "select 100 + 23", .mu = PTHREAD_MUTEX_INITIALIZER},
  };

  pthread_t hb;
  pthread_create(&hb, NULL, heartbeat, NULL);

  pthread_t th[CONNS];
  for (int i = 0; i < CONNS; i++) {
    pthread_create(&th[i], NULL, worker, &jobs[i]);
  }

  // 主线程「await」：阻塞读门铃。真实绑定里这里是 RawFdStream::read。
  // 一次通知可能对应多个完成 —— 这里正好收到 CONNS 个字节。
  for (int got = 0; got < CONNS; got++) {
    char b;
    if (read(bell[0], &b, 1) != 1) {
      perror("read bell");
      return 1;
    }
  }

  for (int i = 0; i < CONNS; i++) pthread_join(th[i], NULL);
  pthread_join(hb, NULL);

  printf("结果：");
  for (int i = 0; i < CONNS; i++) {
    pthread_mutex_lock(&jobs[i].mu);
    printf("conn%d = %lld%s ", jobs[i].id, (long long)jobs[i].result, jobs[i].ok ? "" : "(失败)");
    pthread_mutex_unlock(&jobs[i].mu);
  }
  printf("\n");

  close(bell[0]);
  close(bell[1]);
  return 0;
}
