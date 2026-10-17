package main

import (
	"database/sql"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"strings"
)

type seedSize struct {
	Users, Articles, Tags int
}

// defaultSeed is small enough for a 1 GB node: about 40 MB on disk, fully page-cached.
var defaultSeed = seedSize{Users: 2000, Articles: 20000, Tags: 50}

const schema = `
CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, bio TEXT, image TEXT);
CREATE TABLE follows (follower_id INTEGER NOT NULL, followee_id INTEGER NOT NULL,
  PRIMARY KEY (follower_id, followee_id)) WITHOUT ROWID;
CREATE TABLE articles (id INTEGER PRIMARY KEY, slug TEXT NOT NULL UNIQUE, author_id INTEGER NOT NULL,
  title TEXT NOT NULL, description TEXT NOT NULL, body TEXT NOT NULL,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE article_tags (article_id INTEGER NOT NULL, tag_id INTEGER NOT NULL,
  PRIMARY KEY (article_id, tag_id)) WITHOUT ROWID;
CREATE TABLE favorites (user_id INTEGER NOT NULL, article_id INTEGER NOT NULL,
  PRIMARY KEY (user_id, article_id)) WITHOUT ROWID;
CREATE INDEX favorites_article_idx ON favorites (article_id, user_id);
`

// seed writes a deterministic database: article i has slug "article-i", user i has id i.
func seed(path string, n seedSize) error {
	_ = os.Remove(path)
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		return err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		return err
	}

	rng := rand.New(rand.NewPCG(1, 2))
	// lognormal with mean ≈ e^(mu + 0.5), capped.
	lognormal := func(mu float64, limit int) int { return min(int(math.Exp(mu+rng.NormFloat64())), limit) }
	body := strings.Repeat("Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", 18) // ~1 KB
	const t0 = int64(1735689600000)                                                         // 2025-01-01

	tx, err := db.Begin()
	if err != nil {
		return err
	}
	exec := func(q string, args ...any) {
		if err == nil {
			_, err = tx.Exec(q, args...)
		}
	}
	for i := 1; i <= n.Tags; i++ {
		exec(`INSERT INTO tags (id, name) VALUES (?, ?)`, i, fmt.Sprintf("tag%02d", i))
	}
	for i := 1; i <= n.Users; i++ {
		exec(`INSERT INTO users (id, username, bio) VALUES (?, ?, ?)`, i, fmt.Sprintf("user%d", i), "bio")
		for range lognormal(2.5, 100) {
			exec(`INSERT OR IGNORE INTO follows VALUES (?, ?)`, i, 1+rng.IntN(n.Users))
		}
	}
	for i := 1; i <= n.Articles; i++ {
		created := t0 + int64(i)*60_000
		exec(`INSERT INTO articles VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			i, fmt.Sprintf("article-%d", i), 1+rng.IntN(n.Users), fmt.Sprintf("Article %d", i), "description", body, created, created)
		for range 1 + rng.IntN(4) {
			exec(`INSERT OR IGNORE INTO article_tags VALUES (?, ?)`, i, 1+rng.IntN(n.Tags))
		}
		for range lognormal(1.8, 500) {
			exec(`INSERT OR IGNORE INTO favorites VALUES (?, ?)`, 1+rng.IntN(n.Users), i)
		}
	}
	if err != nil {
		_ = tx.Rollback()
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	_, err = db.Exec(`VACUUM; ANALYZE;`)
	return err
}
