# VARIANT: baseline | manual | otelc. The goauto variant runs the baseline image.
# Go 1.26.1 is pinned because Go auto-instrumentation v0.24.0 ships offsets up to it.
FROM golang:1.26.1 AS build
ARG VARIANT=baseline
ARG OTELC_VERSION=v1.2.0
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN mkdir /out && go run . -seed /out/conduit.db
RUN case "$VARIANT" in \
      baseline) go build -o /out/conduit . ;; \
      manual)   go build -tags manual -o /out/conduit . ;; \
      otelc)    curl -fsSL -o /usr/local/bin/otelc \
                  "https://github.com/open-telemetry/opentelemetry-go-compile-instrumentation/releases/download/${OTELC_VERSION}/otelc-linux-$(go env GOARCH)" \
                && chmod +x /usr/local/bin/otelc && otelc go build -o /out/conduit . ;; \
      *) echo "unknown VARIANT $VARIANT" && exit 1 ;; \
    esac

FROM alpine:3.22
COPY --from=build /out/ /app/
ENTRYPOINT ["/app/conduit"]
