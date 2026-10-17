.DEFAULT_GOAL := help
SHELL := bash

# Passed through to bench.sh, e.g. `make run V=otelc RATE=300 DURATION=5m`.
export RATE DURATION WARMUP ROUNDS PROFILE JWT_SECRET SKIP_DEPLOY STARTUP_WINDOW CEILING_RATES CEILING_STEP CEILING_P99_MS

V ?= otelc
VARIANTS := baseline manual otelc goauto
GO := GOTOOLCHAIN=go1.26.1 go

.PHONY: help
help: ## list targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z0-9-]+:.*## / {printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ develop
.PHONY: test lint fmt seed
test: ## go test the service
	cd service && $(GO) test ./...

lint: ## gofmt check, go vet (both build tags), shellcheck
	@test -z "$$(gofmt -l service)" || (gofmt -l service && exit 1)
	cd service && $(GO) vet ./... && $(GO) vet -tags manual ./...
	shellcheck bench.sh

fmt: ## gofmt -w
	gofmt -w service

seed: ## write the seed database to /tmp/conduit.db
	cd service && $(GO) run . -seed /tmp/conduit.db

##@ cluster
.PHONY: images cluster infra tilt clean
images: ## build bench/conduit:{baseline,manual,otelc}
	./bench.sh images

cluster: images ## local k3d cluster with a registry, images imported, Jaeger deployed
	./bench.sh local-cluster

infra: ## namespace + Jaeger on the current cluster
	./bench.sh infra

tilt: ## live dev loop for one variant: make tilt V=goauto
	tilt up -- --variant $(V)

clean: ## delete the local k3d cluster
	k3d cluster delete bench

##@ benchmark
.PHONY: coverage coverage-all startup startup-all ceiling ceiling-all run all report
coverage: ## span + trace-context check for one variant: make coverage V=manual
	./bench.sh coverage $(V)

coverage-all: ## coverage check for every variant
	@for v in $(VARIANTS); do ./bench.sh coverage $$v || exit 1; done

startup: ## startup time + time to first span: make startup V=goauto
	./bench.sh startup $(V)

startup-all: ## startup check for every variant, ROUNDS times
	@for r in $$(seq $${ROUNDS:-3}); do for v in $(VARIANTS); do ./bench.sh startup $$v || exit 1; done; done
	@column -t -s, results/startup.csv

ceiling: ## max rate before p99 / errors / drops cross a limit: make ceiling V=otelc CEILING_P99_MS=25
	./bench.sh ceiling $(V)

ceiling-all: ## ceiling for every variant
	@for v in $(VARIANTS); do ./bench.sh ceiling $$v || exit 1; done
	@column -t -s, results/ceiling.csv

run: ## one measured run: make run V=goauto RATE=200 DURATION=3m
	./bench.sh run $(V)

all: ## ROUNDS x every variant, rotating order, then report
	./bench.sh all

report: ## medians per variant vs baseline from results/results.csv
	./bench.sh report
