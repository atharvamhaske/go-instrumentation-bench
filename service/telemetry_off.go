//go:build !manual

package main

import (
	"context"
	"database/sql"
	"net/http"
)

func setupTelemetry(context.Context) (func(context.Context) error, error) {
	return func(context.Context) error { return nil }, nil
}

func openDB(driver, dsn string) (*sql.DB, error) { return sql.Open(driver, dsn) }

func wrapHandler(h http.Handler) http.Handler { return h }
