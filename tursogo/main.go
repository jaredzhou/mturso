package main

import (
	"bytes"
	"context"
	"database/sql"
	"flag"
	"fmt"
	"os"
	"time"

	turso "turso.tech/database/tursogo-serverless"
)

func serverURL() string {
	if value := os.Getenv("MTURSO_SERVER_URL"); value != "" {
		return value
	}
	return "http://127.0.0.1:8080"
}

func main() {
	url := flag.String("url", serverURL(), "mturso native server URL")
	flag.Parse()

	db := sql.OpenDB(turso.NewConnector(*url, ""))
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	statements := []string{
		"drop table if exists tursogo_smoke",
		"create table tursogo_smoke(id integer primary key, name text, payload blob)",
	}
	for _, statement := range statements {
		if _, err := db.ExecContext(ctx, statement); err != nil {
			panic(err)
		}
	}

	if _, err := db.ExecContext(
		ctx,
		"insert into tursogo_smoke values (?, ?, ?)",
		1,
		"official-sdk",
		[]byte{1, 2, 3},
	); err != nil {
		panic(err)
	}

	var (
		id      int64
		name    string
		payload []byte
	)
	if err := db.QueryRowContext(
		ctx,
		"select id, name, payload from tursogo_smoke where id = ?",
		1,
	).Scan(&id, &name, &payload); err != nil {
		panic(err)
	}
	if id != 1 || name != "official-sdk" || !bytes.Equal(payload, []byte{1, 2, 3}) {
		panic(fmt.Sprintf(
			"unexpected row: id=%d name=%q payload=%v",
			id,
			name,
			payload,
		))
	}

	fmt.Println("tursogo-serverless: ok")
}
