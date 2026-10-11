package main

import (
	"database/sql"
	"fmt"
)

// runVector 演示向量检索：用 vector32() 构造向量，用距离函数做最近邻查询。
func runVector() error {
	fmt.Println("\n### vector：向量检索")

	db, err := sql.Open("turso", ":memory:")
	if err != nil {
		return err
	}
	defer db.Close()

	if _, err := db.Exec(`create table docs(id integer primary key, title text, emb blob)`); err != nil {
		return err
	}

	docs := []struct {
		title string
		emb   string // JSON 数组文本，交给 vector32() 构造
	}{
		{"猫", "[1.0, 0.1, 0.0]"},
		{"狗", "[0.9, 0.2, 0.1]"},
		{"汽车", "[0.0, 0.9, 0.9]"},
		{"卡车", "[0.1, 0.95, 0.8]"},
	}
	stmt, err := db.Prepare(`insert into docs(title, emb) values (?, vector32(?))`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, d := range docs {
		if _, err := stmt.Exec(d.title, d.emb); err != nil {
			return err
		}
	}

	// 查询向量语义上接近「猫/狗」
	query := "[1.0, 0.05, 0.0]"
	rows, err := db.Query(`
		select id, title, vector_distance_cos(emb, vector32(?)) as dist
		from docs order by dist limit 3`, query)
	if err != nil {
		return err
	}
	defer rows.Close()
	fmt.Printf("  查询 %s 的 top-3（cosine 距离，越小越近）：\n", query)
	for rows.Next() {
		var (
			id    int64
			title string
			dist  float64
		)
		if err := rows.Scan(&id, &title, &dist); err != nil {
			return err
		}
		fmt.Printf("    #%d %-4s dist=%.4f\n", id, title, dist)
	}
	if err := rows.Err(); err != nil {
		return err
	}

	var l2, dot float64
	if err := db.QueryRow(`
		select vector_distance_l2(vector32('[1,0,0]'), vector32('[0,1,0]')),
		       vector_distance_dot(vector32('[1,2,3]'), vector32('[4,5,6]'))`).Scan(&l2, &dot); err != nil {
		return err
	}
	// 注意：vector_distance_* 一律是「距离」语义（越小越近），dot 距离 = 负的内积。
	fmt.Printf("  L2([1,0,0],[0,1,0])=%.4f  Dot([1,2,3],[4,5,6])=%.1f（= -32，负内积）\n", l2, dot)
	return nil
}
