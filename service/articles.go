package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	articleBySlug = `SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ?1),
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ?1 AND fo.followee_id = a.author_id)
  FROM articles a
  JOIN users u ON u.id = a.author_id
 WHERE a.slug = ?2`

	tagsByArticle = `SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
 WHERE at.article_id = ?1 ORDER BY t.name`

	allTags = `SELECT name FROM tags ORDER BY name`
)

type profileJSON struct {
	Username  string  `json:"username"`
	Bio       *string `json:"bio"`
	Image     *string `json:"image"`
	Following bool    `json:"following"`
}

type articleJSON struct {
	Slug           string      `json:"slug"`
	Title          string      `json:"title"`
	Description    string      `json:"description"`
	Body           string      `json:"body"`
	TagList        []string    `json:"tagList"`
	CreatedAt      ts          `json:"createdAt"`
	UpdatedAt      ts          `json:"updatedAt"`
	Favorited      bool        `json:"favorited"`
	FavoritesCount int64       `json:"favoritesCount"`
	Author         profileJSON `json:"author"`
}

// ts is unix milliseconds rendered as RFC 3339 UTC with 3 fractional digits.
type ts int64

func (t ts) MarshalJSON() ([]byte, error) {
	return []byte(`"` + time.UnixMilli(int64(t)).UTC().Format("2006-01-02T15:04:05.000Z") + `"`), nil
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/articles/{slug}", a.getArticle)
	mux.HandleFunc("GET /api/tags", a.tags)
	return mux
}

// getArticle is the request path under test: JWT verify, two SQL queries, JSON encode.
func (a *app) getArticle(w http.ResponseWriter, r *http.Request) {
	viewer, ok := a.auth(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	var x articleJSON
	var id int64
	err := a.db.QueryRowContext(r.Context(), articleBySlug, viewer, r.PathValue("slug")).Scan(
		&id, &x.Slug, &x.Title, &x.Description, &x.Body, &x.CreatedAt, &x.UpdatedAt,
		&x.FavoritesCount, &x.Favorited, &x.Author.Username, &x.Author.Bio, &x.Author.Image, &x.Author.Following)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "article not found")
		return
	}
	if err != nil {
		internalError(w, err)
		return
	}

	x.TagList, err = a.strings(r, tagsByArticle, id)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Article articleJSON `json:"article"`
	}{x})
}

func (a *app) tags(w http.ResponseWriter, r *http.Request) {
	tags, err := a.strings(r, allTags)
	if err != nil {
		internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Tags []string `json:"tags"`
	}{tags})
}

func (a *app) strings(r *http.Request, query string, args ...any) ([]string, error) {
	rows, err := a.db.QueryContext(r.Context(), query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// auth verifies "Authorization: Token <HS256 JWT>" and returns the user id from "sub".
func (a *app) auth(r *http.Request) (int64, bool) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Token ")
	if !ok {
		return 0, false
	}
	var claims jwt.RegisteredClaims
	_, err := jwt.ParseWithClaims(token, &claims, func(*jwt.Token) (any, error) { return a.secret, nil },
		jwt.WithValidMethods([]string{"HS256"}), jwt.WithExpirationRequired())
	if err != nil {
		return 0, false
	}
	id, err := strconv.ParseInt(claims.Subject, 10, 64)
	return id, err == nil && id > 0
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		log.Printf("encode response: %v", err)
		status, b = http.StatusInternalServerError, []byte(`{"errors":{"body":["internal error"]}}`)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(b)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]map[string][]string{"errors": {"body": {msg}}})
}

func internalError(w http.ResponseWriter, err error) {
	log.Printf("error: %v", err)
	writeError(w, http.StatusInternalServerError, "internal error")
}
