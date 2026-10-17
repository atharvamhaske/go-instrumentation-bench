//go:build manual

package main

import (
	"context"
	"database/sql"
	"net/http"

	"github.com/XSAM/otelsql"
	"go.opentelemetry.io/contrib/exporters/autoexport"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/contrib/propagators/autoprop"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// setupTelemetry mirrors what otelc injects: autoexport + autoprop + a batching tracer
// provider, all driven by the standard OTEL_* environment variables.
func setupTelemetry(ctx context.Context) (func(context.Context) error, error) {
	exp, err := autoexport.NewSpanExporter(ctx)
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(autoprop.NewTextMapPropagator())
	return tp.Shutdown, nil
}

// openDB emits one span per query, matching otelc and Go auto-instrumentation.
func openDB(driver, dsn string) (*sql.DB, error) {
	return otelsql.Open(driver, dsn,
		otelsql.WithAttributes(attribute.String("db.system.name", "sqlite")),
		otelsql.WithSpanOptions(otelsql.SpanOptions{
			OmitConnResetSession: true,
			OmitConnPrepare:      true,
			OmitConnectorConnect: true,
			OmitRows:             true,
		}))
}

func wrapHandler(h http.Handler) http.Handler {
	return otelhttp.NewHandler(h, "conduit",
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string { return r.Method }))
}
