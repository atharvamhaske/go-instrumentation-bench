package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func TestGetArticle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")
	if err := seed(path, seedSize{Users: 20, Articles: 50, Tags: 5}); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro&immutable=1")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a := &app{db: db, secret: []byte("s")}
	h := a.routes()

	token, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.RegisteredClaims{
		Subject:   strconv.Itoa(3),
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}).SignedString(a.secret)

	get := func(path, auth string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if auth != "" {
			req.Header.Set("Authorization", "Token "+auth)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}

	if rec := get("/api/articles/article-7", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no token: got %d, want 401", rec.Code)
	}
	if rec := get("/api/articles/nope", token); rec.Code != http.StatusNotFound {
		t.Fatalf("missing article: got %d, want 404", rec.Code)
	}

	rec := get("/api/articles/article-7", token)
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d: %s", rec.Code, rec.Body)
	}
	var got struct {
		Article struct {
			Slug      string
			TagList   []string
			CreatedAt string
			Author    struct{ Username string }
		}
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	x := got.Article
	if x.Slug != "article-7" || len(x.TagList) == 0 || x.Author.Username == "" || x.CreatedAt == "" {
		t.Fatalf("unexpected article: %s", rec.Body)
	}
}
