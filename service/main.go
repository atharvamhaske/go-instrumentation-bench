// Command conduit is a read-only slice of the RealWorld "Conduit" API backed by SQLite,
// ported from github.com/arjaythedev/multicore-server-challenge/examples/go.
//
// The same source builds every benchmark variant:
//
//	baseline  go build .              (no telemetry)
//	manual    go build -tags manual . (OpenTelemetry SDK, otelhttp, otelsql)
//	otelc     otelc go build .        (compile-time instrumentation)
//	goauto    baseline binary + eBPF auto-instrumentation sidecar
package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"log"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	_ "modernc.org/sqlite"
)

type app struct {
	db     *sql.DB
	secret []byte
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func main() {
	seedPath := flag.String("seed", "", "write a deterministic seed database to this path and exit")
	flag.Parse()
	if *seedPath != "" {
		if err := seed(*seedPath, defaultSeed); err != nil {
			log.Fatal(err)
		}
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdownTelemetry, err := setupTelemetry(ctx)
	if err != nil {
		log.Fatalf("telemetry: %v", err)
	}

	db, err := openDB("sqlite", "file:"+envOr("DB_PATH", "/app/conduit.db")+"?mode=ro&immutable=1")
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer db.Close()
	conns := runtime.GOMAXPROCS(0) * 2
	db.SetMaxOpenConns(conns)
	db.SetMaxIdleConns(conns)

	a := &app{db: db, secret: []byte(envOr("JWT_SECRET", "bench-secret"))}
	srv := &http.Server{
		Addr:              ":" + envOr("PORT", "8080"),
		Handler:           wrapHandler(a.routes()),
		IdleTimeout:       75 * time.Second,
		ReadHeaderTimeout: 10 * time.Second,
	}

	// pprof stays on its own port so it is never part of the measured request path.
	if addr := os.Getenv("PPROF_ADDR"); addr != "" {
		go func() { log.Println(http.ListenAndServe(addr, nil)) }()
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
		_ = shutdownTelemetry(sctx)
	}()

	log.Printf("conduit listening on %s (GOMAXPROCS=%d, db conns=%d)", srv.Addr, runtime.GOMAXPROCS(0), conns)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	<-done
}
