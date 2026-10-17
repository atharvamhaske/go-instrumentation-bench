# go-instrumentation-bench

How much does tracing a Go service cost, and what do you actually get for it?

This repo runs the same Go service four ways and puts the same load on each:

| Variant | How it's built | What does the tracing |
|---|---|---|
| `baseline` | `go build` | nothing |
| `manual` | `go build -tags manual` | OpenTelemetry SDK, `otelhttp`, `otelsql`, wired up by hand |
| `otelc` | `otelc go build` | [compile-time instrumentation](https://github.com/open-telemetry/opentelemetry-go-compile-instrumentation) v1.2.0, injected at build time |
| `goauto` | `go build`, same binary as baseline | [eBPF auto-instrumentation](https://github.com/open-telemetry/opentelemetry-go-instrumentation) v0.24.0, running as a sidecar |

It's the demo for the talk *Comparing the Cost and Coverage of Go Instrumentation*.

## Why coverage comes first

A tracer that records less will look cheaper. If one variant creates a span per database query
and another only creates the HTTP span, comparing their CPU says nothing about which approach
is cheaper. So before measuring anything, `bench.sh coverage` sends one request with a known
`traceparent` and prints what each variant actually recorded. Here's what that check found on
a local cluster:

| | server span | `http.route` | DB span name | DB attributes |
|---|---|---|---|---|
| manual | `GET` | no | `sql.conn.query` | `db.query.text`, `db.system.name` |
| otelc | `GET /api/articles/{slug}` | yes | `SELECT` | `db.query.text`, `db.system.name`, `db.operation.name`, `db.namespace`, `server.address`, `network.transport` |
| goauto | `GET /api/articles/{slug}` | yes | `DB` | `db.query.text` |

All three emit 3 spans per request, honor the incoming `traceparent`, and nest both database
spans under the server span. They are not the same spans, though. `manual` misses the route
because `otelhttp` wraps the router from the outside and never sees which pattern matched.
`goauto` records the least about each query.

## Why the agent's CPU counts

`goauto` doesn't touch the binary. It attaches eBPF uprobes from a separate privileged process.
Its cost lands in two places:

- **The app container.** Uprobe handlers run in the kernel on the app's own threads, so the
  kernel bills them to the app's cgroup.
- **The agent container.** Reading events out of the kernel, building spans and exporting them
  happens in the sidecar.

If you only look at the app container, eBPF looks nearly free. `bench.sh` records both, and
`report` shows the total plus how much of it was the agent.

## The service

`service/` is a small read-only slice of the RealWorld "Conduit" API (a Medium clone), ported
from the Go example in
[multicore-server-challenge](https://github.com/arjaythedev/multicore-server-challenge/tree/main/examples/go)
from Postgres to SQLite. It uses `modernc.org/sqlite` (pure Go, no cgo) through `database/sql`,
because `database/sql` is the one database API that all three approaches can instrument.

The request under load is:

```
GET /api/articles/{slug}
Authorization: Token <HS256 JWT>
traceparent: 00-<trace id>-<span id>-01

  verify JWT
  query 1: article + author + favorites count + favorited + following
  query 2: tag names
  encode JSON
```

That's real work, not a hello-world handler. The JWT check costs real CPU and the queries do
joins and subqueries. It's also small enough to reason about: one server span and two client
spans.

The database is generated at image build time with a fixed random seed: 2,000 users, 20,000
articles with ~1 KB bodies, ~190k favorites, ~38k follows. It's 33 MB and opened read-only, so
it lives in the page cache and every run sees the same data.

Full endpoint, config and CSV reference: [docs/API.md](docs/API.md).

## What stays the same across variants

The comparison is only as good as the things you hold constant. Here's what the setup pins:

- **Source and toolchain.** One source tree, Go 1.26.1, same build flags. Only the build command
  changes. Go 1.26.1 is pinned because agent v0.24.0 only has offsets up to that version.
- **Offered load.** k6 uses `constant-arrival-rate`: it starts N requests per second no matter
  how fast responses come back. A slow variant shows up as higher latency or `dropped`
  iterations instead of quietly receiving less traffic. (With a fixed number of virtual users,
  a slower service would get fewer requests and look less busy.)
- **Telemetry settings,** all through standard env vars: `always_on` sampling, batch span
  processor, OTLP http/protobuf to Jaeger, `tracecontext,baggage` propagators. Metrics and logs
  exporters are set to `none`, since otelc would otherwise also export metrics and the others
  don't.
- **Span shape.** `otelsql` is told to skip its extra spans (rows, connect, reset session) so it
  emits one span per query, like the other two.
- **Placement.** The app runs alone on the node labelled `bench/app`, with `GOMAXPROCS=2`. k6 and
  Jaeger run on the `bench/load` node. The app pays for creating and sending spans, not for
  storing them.
- **Fresh backend.** Jaeger is restarted before every run, so a full in-memory store never slows
  the exporter down.
- **Order.** `make all` rotates the variant order each round. Slow drift (a warming CPU, a noisy
  neighbor) spreads over every variant instead of hitting whichever one ran last.

## What gets measured

| Metric | Source |
|---|---|
| p50, p99 latency | k6, client side |
| CPU per request, app container | kubelet `/stats/summary` (`usageCoreNanoSeconds`), before and after the measured window, divided by request count |
| CPU per request, agent container | same, for the `goauto` sidecar |
| memory | working set at the end of the run |
| CPU profile (optional) | `PROFILE=1` pulls a 30s pprof profile mid-run |

CPU per request is used instead of "average cores" because it doesn't depend on how long the
window was. The kubelet only refreshes its counters every ~10s, so the script waits 20s on
either side of the measured window while the pod is idle.

Profiling isn't free either. Profiled runs are written with `profiled=1` and left out of the
report, and comparing them with the unprofiled runs shows what the profiler costs. In a quick
local check, the same otelc build used 1.16 ms of CPU per request with the profiler running and
1.04 ms without.

## Quick start (macOS)

You need Docker (Docker Desktop or OrbStack), `k3d`, `kubectl`, `jq`, Go 1.26+ and optionally
`tilt`. eBPF needs a Linux kernel; k3d runs k3s inside Docker's Linux VM, and that's enough
for `goauto`.

```sh
make cluster        # build images, create k3d cluster + registry, deploy Jaeger
make coverage-all   # the coverage check for all four variants
make run V=otelc RATE=100 DURATION=30s WARMUP=10s
make report
```

Jaeger UI: `kubectl -n bench port-forward svc/jaeger 16686`, then open http://localhost:16686.

Laptop numbers are fine for building the demo and wrong for the talk: k6, Jaeger and the app all
share the same cores.

### Dev loop with Tilt

```sh
make tilt V=goauto   # or baseline | manual | otelc
```

Tilt rebuilds and redeploys on every change under `service/`, forwards `8080` (app), `6060`
(pprof) and `16686` (Jaeger), runs `go test` on change, and has a `coverage` button. Use it while
changing the service, not while benchmarking: rebuilds and file watching add noise.

## Running it for real

You need two Linux machines in the same private network: one for the app, one for load and
Jaeger. Put the k3s server (control plane) on the **load** node so it never competes with the
app.

### Picking machines

The app node is the one that matters. Shared-vCPU VMs lose CPU time to other tenants (CPU
steal), which looks exactly like instrumentation overhead.

| Option | App node | Load node | Notes |
|---|---|---|---|
| DigitalOcean (GitHub Student Pack credit) | CPU-Optimized, 2 dedicated vCPU | Basic, 2 vCPU / 4 GB | Billed hourly. Create, run, destroy: a session costs well under $1 |
| Oracle Cloud Always Free | Ampere A1, 2 OCPU / 12 GB | Ampere A1, 2 OCPU / 12 GB | Free, ARM, no CPU credits. Capacity is often short in popular regions |

Avoid burstable instances (AWS `t*`, GCP `e2-micro`) for measured runs. They throttle when
credits run out.

### Setup

1. Create both machines with Ubuntu 24.04 in the same VPC or subnet.
   On Oracle, open the subnet in both the VCN security list and iptables (see
   [RUNBOOK.md](RUNBOOK.md#oracle-cloud-agent-node-never-joins)).
2. Load node, k3s server:
   ```sh
   curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 644
   sudo cat /var/lib/rancher/k3s/server/node-token
   ```
3. App node, k3s agent and Docker, then build the images there:
   ```sh
   curl -sfL https://get.k3s.io | K3S_URL=https://<load-node-private-ip>:6443 K3S_TOKEN=<token> sh -
   curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker $USER && newgrp docker
   git clone <this repo> && cd go-instrumentation-bench
   make images && ./bench.sh import-k3s
   ```
4. Load node, label the nodes and deploy Jaeger:
   ```sh
   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
   git clone <this repo> && cd go-instrumentation-bench
   kubectl label node <app-node> bench/app=true
   kubectl label node <load-node> bench/load=true
   make infra
   ```
5. Follow [RUNBOOK.md](RUNBOOK.md): coverage, find the rate, run the rounds, check the numbers,
   tear down.

## Commands

`make help` lists everything. The ones you'll use:

| Command | What it does |
|---|---|
| `make cluster` | local k3d cluster with registry, images imported, Jaeger deployed |
| `make tilt V=<variant>` | live dev loop |
| `make coverage V=<variant>` / `make coverage-all` | span and trace-context check |
| `make run V=<variant>` | warmup, measured run, one CSV row |
| `make all` | `ROUNDS` × every variant, rotating order, then the report |
| `make report` | medians per variant compared with baseline |
| `make test` / `make lint` | service test; gofmt, go vet for both builds, shellcheck |
| `make clean` | delete the local cluster |

Knobs, as env vars or make variables: `RATE` (requests/s, default 200), `DURATION` (3m),
`WARMUP` (30s), `ROUNDS` (3), `PROFILE` (0 or 1).

## Layout

```
service/
  main.go               server, DB pool, optional pprof listener
  articles.go           handlers, auth, SQL
  seed.go               deterministic seed database (`conduit -seed <path>`)
  telemetry_off.go      no-op hooks for baseline / otelc / goauto builds
  telemetry_manual.go   SDK setup, otelhttp, otelsql (build tag `manual`)
  articles_test.go      handler test against a small seed
  Dockerfile            VARIANT=baseline|manual|otelc
k8s/
  infra.yaml            namespace + Jaeger, on the load node
  app.yaml              baseline / manual / otelc Deployment template
  app-goauto.yaml       baseline image + privileged eBPF agent sidecar
  k6-job.yaml           k6 Job, on the load node
k6/article.js           load script; signs its own JWTs, sends a fresh traceparent per request
bench.sh                every command the Makefile wraps
Tiltfile                dev loop
docs/API.md             endpoints, config, data model, CSV columns
RUNBOOK.md              session checklist and troubleshooting
```

## Known limits

- **One request path.** The results describe this path (HTTP in, two SQLite queries, JSON out).
  A service with more spans per request, or outbound HTTP calls, will see different ratios.
- **SQLite runs in-process,** so database CPU counts as app CPU. It's the same for every variant,
  so differences are still meaningful, but the percentages are relative to a heavier baseline
  than a service that waits on a network database.
- **No outbound propagation test.** The service doesn't call another service, so injecting
  `traceparent` into outgoing requests isn't covered. This is where `goauto` is weakest, since
  it has to write the header into process memory from outside.
- **eBPF agent support trails Go releases.** Agent v0.24.0 tops out at Go 1.26.1. Bumping Go means
  checking the agent's release notes first.
