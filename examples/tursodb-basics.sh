#!/usr/bin/env bash
# tursodb 基础用法示例 —— 已实测（Turso 0.8.2）
set -euo pipefail

TURSODB="${TURSODB:-$HOME/.turso/tursodb}"
workdir="$(mktemp -d)"
db="$workdir/demo.db"

echo "== 版本 =="
"$TURSODB" --version

echo
echo "== 内存库：表达式 =="
"$TURSODB" -q :memory: "select 1 + 1 as sum, 'hi' as s;"

echo
echo "== 文件库：建表 / 写入 / 查询 =="
"$TURSODB" -q "$db" \
  "create table t(id integer primary key, name text);
   insert into t(name) values ('alice'),('bob');
   select * from t;"

echo
echo "== 兼容性信息 =="
"$TURSODB" -q "$db" "select sqlite_version() as sqlite_version;"

echo
echo "== list 输出模式 =="
"$TURSODB" -q -m list "$db" "select id, name from t order by id;"

echo
echo "== 事务回滚 =="
"$TURSODB" -q "$db" \
  "begin; insert into t(name) values ('carol'); rollback;
   select count(*) as after_rollback from t;"

echo
echo "临时目录：$workdir（数据保留在此，可自行删除）"
