package main

import (
	"database/sql"
	"fmt"
	"path/filepath"
)

// change_type 取值来自 core/translate/emitter/mod.rs（v2 还会写 change_type=2 的 COMMIT 记录）。
var cdcChangeType = map[int64]string{1: "INSERT", 0: "UPDATE", -1: "DELETE", 2: "COMMIT"}

// runCDC 演示变更数据捕获：所有 DML 变更会写进 turso_cdc 表。
func runCDC() error {
	fmt.Println("\n### cdc：变更数据捕获")

	dir, cleanup, err := tempDir()
	if err != nil {
		return err
	}
	defer cleanup()

	db, err := sql.Open("turso", filepath.Join(dir, "cdc.db"))
	if err != nil {
		return err
	}
	defer db.Close()
	// PRAGMA 是「按连接」生效的：固定单连接，确保开启 CDC 的连接就是执行写入的连接。
	db.SetMaxOpenConns(1)

	// full 模式：记录变更前后的完整行。见 cli/manuals/cdc.md 与 core/cdc.rs。
	if _, err := db.Exec(`PRAGMA capture_data_changes_conn('full')`); err != nil {
		return err
	}
	if _, err := db.Exec(`create table account(id integer primary key, balance integer)`); err != nil {
		return err
	}
	if _, err := db.Exec(`insert into account(balance) values (100)`); err != nil {
		return err
	}
	if _, err := db.Exec(`update account set balance = 150 where id = 1`); err != nil {
		return err
	}
	if _, err := db.Exec(`delete from account where id = 1`); err != nil {
		return err
	}

	rows, err := db.Query(`select change_id, change_type, table_name, id from turso_cdc order by change_id`)
	if err != nil {
		return err
	}
	defer rows.Close()
	fmt.Println("  turso_cdc（change_type: 1=INSERT 0=UPDATE -1=DELETE 2=COMMIT）：")
	for rows.Next() {
		var (
			cid   int64
			ctype int64
			tbl   sql.NullString
			id    sql.NullInt64
		)
		if err := rows.Scan(&cid, &ctype, &tbl, &id); err != nil {
			return err
		}
		idStr := "-"
		if id.Valid {
			idStr = fmt.Sprint(id.Int64)
		}
		tblStr := tbl.String
		if tblStr == "" {
			tblStr = "-"
		}
		fmt.Printf("    change_id=%-2d type=%-2d(%-6s) table=%-8s id=%s\n",
			cid, ctype, cdcChangeType[ctype], tblStr, idStr)
	}
	return rows.Err()
}
