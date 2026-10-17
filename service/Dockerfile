# VARIANT: baseline | manual | otelc. The goauto variant runs the baseline image.
# Go 1.26.1 is pinned because Go auto-instrumentation v0.24.0 ships offsets up to it.
# The build stage runs natively and cross-compiles, so `--platform linux/amd64` from an ARM Mac
# doesn't run the Go toolchain under emulation.
FROM --platform=$BUILDPLATFORM golang:1.26.1 AS build
ARG VARIANT=baseline
ARG OTELC_VERSION=v1.2.0
ARG TARGETARCH
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN mkdir /out && go run . -seed /out/conduit.db
RUN case "$VARIANT" in \
      baseline) GOARCH=$TARGETARCH go build -o /out/conduit . ;; \
      manual)   GOARCH=$TARGETARCH go build -tags manual -o /out/conduit . ;; \
      otelc)    curl -fsSL --retry 5 --retry-all-errors -o /usr/local/bin/otelc \
                  "https://github.com/open-telemetry/opentelemetry-go-compile-instrumentation/releases/download/${OTELC_VERSION}/otelc-linux-$(go env GOHOSTARCH)" \
                && chmod +x /usr/local/bin/otelc && GOARCH=$TARGETARCH otelc go build -o /out/conduit . ;; \
      *) echo "unknown VARIANT $VARIANT" && exit 1 ;; \
    esac

FROM alpine:3.22
COPY --from=build /out/ /app/
# "process-start" gives `bench.sh startup` a container-runtime timestamp for the moment before
# exec. With START_GATE set, the process waits for /tmp/go so the prober is already running.
ENTRYPOINT ["/bin/sh", "-c", "if [ -n \"$START_GATE\" ]; then until [ -f /tmp/go ]; do sleep 0.05; done; fi; echo process-start; exec /app/conduit \"$@\"", "--"]
