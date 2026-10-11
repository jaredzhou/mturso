package main

import (
	"database/sql"
	"fmt"
	"path/filepath"
)

type widget struct {
	name  string
	price float64
}

// runBasic 演示 :memory: 库的 CRUD 与文件库上的显式事务。
func runBasic() error {
	fmt.Println("### basic：driver 基础")
	if err := basicMemory(); err != nil {
		return err
	}
	return basicFileTx()
}

func basicMemory() error {
	db, err := sql.Open("turso", ":memory:")
	if err != nil {
		return err
	}
	defer db.Close()

	if _, err := db.Exec(`create table widget(id integer primary key, name text, price real)`); err != nil {
		return err
	}

	stmt, err := db.Prepare(`insert into widget(name, price) values (?, ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, w := range []widget{{"bolt", 0.12}, {"nut", 0.03}, {"washer", 0.01}} {
		if _, err := stmt.Exec(w.name, w.price); err != nil {
			return err
		}
	}

	var version string
	if err := db.QueryRow(`select sqlite_version()`).Scan(&version); err != nil {
		return err
	}
	fmt.Printf("  sqlite_version() = %s\n", version)

	rows, err := db.Query(`select id, name, price from widget order by id`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			id    int64
			name  string
			price float64
		)
		if err := rows.Scan(&id, &name, &price); err != nil {
			return err
		}
		fmt.Printf("  %d\t%-7s %.2f\n", id, name, price)
	}
	return rows.Err()
}

func basicFileTx() error {
	dir, cleanup, err := tempDir()
	if err != nil {
		return err
	}
	defer cleanup()

	path := filepath.Join(dir, "basic.db")
	db, err := sql.Open("turso", path)
	if err != nil {
		return err
	}
	defer db.Close()

	if _, err := db.Exec(`create table item(id integer primary key, label text)`); err != nil {
		return err
	}
	if _, err := db.Exec(`insert into item(label) values ('keep')`); err != nil {
		return err
	}

	tx, err := db.Begin()
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`insert into item(label) values ('discard')`); err != nil {
		return err
	}
	if err := tx.Rollback(); err != nil {
		return err
	}

	var count int
	if err := db.QueryRow(`select count(*) from item`).Scan(&count); err != nil {
		return err
	}
	fmt.Printf("  文件库 %s：提交 1 行、回滚 1 行后 count = %d（期望 1）\n", filepath.Base(path), count)
	return nil
}
