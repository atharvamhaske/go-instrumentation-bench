.DEFAULT_GOAL := help
SHELL := bash

# Passed through to bench.sh / aws/aws.sh, e.g. `make run V=otelc RATE=300 DURATION=5m`.
export RATE DURATION WARMUP ROUNDS PROFILE JWT_SECRET SKIP_DEPLOY STARTUP_WINDOW CEILING_RATES CEILING_STEP CEILING_P99_MS
export REGISTRY FORCE AWS_REGION HOST ZONE_ID EMAIL BUDGET_USD APP_TYPE LOAD_TYPE ALLOW_CIDR

V ?= otelc
VARIANTS := baseline manual otelc goauto
GO := GOTOOLCHAIN=go1.26.1 go

.PHONY: help
help: ## list targets
	@awk 'BEGIN {FS = ":.*## "} /^##@/ {printf "\n%s\n", substr($$0, 5)} /^[a-z0-9-]+:.*## / {printf "  \033[1m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ develop
.PHONY: test lint fmt seed
test: ## go test the service and the launcher
	cd service && $(GO) test ./...
	cd launcher && $(GO) test ./...

lint: ## gofmt check, go vet (both build tags), shellcheck, JSON check
	@test -z "$$(gofmt -l service launcher)" || (gofmt -l service launcher && exit 1)
	cd service && $(GO) vet ./... && $(GO) vet -tags manual ./...
	cd launcher && $(GO) vet ./...
	shellcheck bench.sh aws/aws.sh
	jq empty k8s/dashboard.json

fmt: ## gofmt -w
	gofmt -w service launcher

seed: ## write the seed database to /tmp/conduit.db
	cd service && $(GO) run . -seed /tmp/conduit.db

##@ cluster
.PHONY: images cluster infra tilt clean observability site-up site-down
images: ## build bench/conduit:{baseline,manual,otelc} and bench/launcher
	./bench.sh images

cluster: images ## local k3d cluster with a registry, images imported, Jaeger deployed
	./bench.sh local-cluster

infra: ## namespace + Jaeger on the current cluster
	./bench.sh infra

tilt: ## live dev loop for one variant: make tilt V=goauto
	tilt up -- --variant $(V)

clean: ## delete the local k3d cluster
	k3d cluster delete bench

observability: ## Prometheus + Grafana on the current cluster
	./bench.sh observability

site-up: ## launcher site: all four variants side by side + launcher
	./bench.sh site-up

site-down: ## remove the site deployments (required before run/ceiling/startup)
	./bench.sh site-down

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

##@ aws (EKS). Order: aws-check aws-budget aws-push aws-up platform [aws-cert aws-ingress aws-dns] ... aws-down
.PHONY: aws-check aws-budget aws-push aws-up platform aws-ingress aws-cert aws-dns aws-url aws-pause aws-resume aws-down aws-leftovers aws-ecr-delete aws-env
aws-check: ## tools, credentials, zones, vCPU quota, cost per day
	aws/aws.sh check

aws-budget: ## cost alert by email: make aws-budget EMAIL=you@example.com [BUDGET_USD=25]
	aws/aws.sh budget

aws-push: ## build linux/amd64 images and push them to ECR
	aws/aws.sh push

aws-up: ## create the EKS cluster + AWS Load Balancer Controller (~20 min)
	aws/aws.sh up

platform: ## Jaeger, Prometheus, Grafana, site, launcher, ALB Ingress on EKS
	aws/aws.sh platform

aws-ingress: ## re-apply the Ingress (HTTPS once HOST has an issued cert)
	aws/aws.sh ingress

aws-cert: ## ACM cert validated via Route 53: make aws-cert HOST=bench.example.com
	aws/aws.sh cert

aws-dns: ## Route 53 alias HOST -> ALB: make aws-dns HOST=bench.example.com
	aws/aws.sh dns

aws-url: ## print the public URL
	aws/aws.sh url

aws-pause: ## scale both node groups to 0 (~$3/day left: control plane + ALB)
	aws/aws.sh pause

aws-resume: ## scale both node groups back to 1
	aws/aws.sh resume

aws-down: ## delete Ingress -> wait for ALB -> DNS record -> cluster, then list leftovers
	aws/aws.sh down

aws-leftovers: ## list anything from this project that still bills
	aws/aws.sh leftovers

aws-ecr-delete: ## delete the ECR repos
	aws/aws.sh ecr-delete

aws-env: ## print `export REGISTRY=...` to run bench.sh against ECR images
	@aws/aws.sh env
