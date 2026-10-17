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

### Capacity ceiling

`make ceiling V=<variant>` asks how much traffic one pod can take before it breaks your latency
target. It steps the offered rate up (`CEILING_RATES`, 30s per step) and stops at the first rate
where p99 goes above `CEILING_P99_MS` (default 25), errors go above 1%, or more than 1% of offered
requests are dropped. A failing step is retried once before it counts, so one spike can't set the
number. The last passing rate is the ceiling.

Comparing ceilings at the same p99 limit gives the number capacity planning actually uses:
if baseline holds 2,000 req/s per pod and a variant holds 1,600, you need 25% more pods for the
same traffic.

### Startup and time to first span

`make startup V=<variant>` answers a different question: when a new pod starts, how long until
it serves, and how long until its requests are actually traced?

The image entrypoint can hold the process behind a gate (`START_GATE=1`). `bench.sh startup`
deploys the variant gated, starts a prober pod that hits the pod IP every ~60 ms, then opens the
gate. Each probe request carries a numbered trace id, so every span maps back to the request
that caused it. All timestamps come from the app node's clock: container runtime log timestamps
for `process-start` and `conduit listening`, and span start times for the first span.

| Column | Meaning |
|---|---|
| `startup_ms` | process exec until the HTTP listener is up. Includes Go runtime init, otelc's SDK init (which runs in `init()`, before `main`) and the manual SDK setup |
| `first_span_ms` | process exec until the start of the first server span. Resolution is the probe interval, ~60 ms |
| `untraced_before_first_span` | requests answered with 200 before the first traced one. These are invisible in your traces |

One local run:

| variant | startup_ms | first_span_ms | untraced requests |
|---|---|---|---|
| baseline | 3.4 | - | all |
| manual | 8.3 | 22 | 0 |
| otelc | 9.4 | 58 | 0 |
| goauto | 2.9 | 595 | 10 |

The in-process approaches pay a few milliseconds at startup and trace from the first request.
`goauto` starts as fast as baseline, because the binary is the baseline, but the agent has to
notice the process (it polls every 2s), read its binary and load the probes. Everything served in
that window goes untraced. For a long-running service that hardly matters. For short-lived jobs,
autoscaling bursts or crash loops, it can be the very traffic you wanted to see.

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

| Option | Free part | App node | Load node | Notes |
|---|---|---|---|---|
| Google Cloud, GKE Standard (zonal) | $300 trial credit for 90 days; one zonal cluster's control plane is free every month | `t2d-standard-2` or `c2d-standard-2` | `e2-standard-4` | Scale node pools to 0 between sessions. Autopilot won't work: it blocks the privileged eBPF agent |
| Azure for Students, AKS free tier | $100 credit for 12 months, no card; AKS control plane is free | `Standard_F2s_v2` | `Standard_D4s_v5` | Student subscriptions have small vCPU quotas; two small nodes fit |
| AWS, EC2 + k3s | up to $200 credit for 6 months (new accounts, Free plan) | `c7i-flex.large` | `m7i-flex.large` | The Free plan only allows `t3`/`t4g` micro and small, `c7i-flex.large` and `m7i-flex.large`. EKS charges $0.10/h for the control plane (~$73/month), so use k3s on EC2. See [AWS step by step](#aws-step-by-step) |
| Oracle Cloud Always Free | 2 Ampere OCPUs + 12 GB in total, forever; OKE basic clusters are free | 1 OCPU | 1 OCPU | Too small for clean numbers since July 2026, but fine for an always-on dashboard. Set `GOMAXPROCS=1` |

Avoid burstable or shared-core instances (AWS `t*`, GCP `e2-micro`/`e2-small`) for the app node.
They throttle when credits run out or share cores with other tenants.

On managed Kubernetes (GKE, AKS, EKS) the nodes can't import local images, so push
`bench/conduit:*` to the provider's registry and change the `image:` lines in `k8s/`.

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
   git clone https://github.com/atharvamhaske/go-instrumentation-bench.git && cd go-instrumentation-bench
   make images && ./bench.sh import-k3s
   ```
4. Load node, label the nodes and deploy Jaeger:
   ```sh
   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
   git clone https://github.com/atharvamhaske/go-instrumentation-bench.git && cd go-instrumentation-bench
   kubectl label node <app-node> bench/app=true
   kubectl label node <load-node> bench/load=true
   make infra
   ```
5. Follow [RUNBOOK.md](RUNBOOK.md): coverage, find the rate, run the rounds, check the numbers,
   tear down.

### AWS step by step

Two instances in the default VPC: `bench-app` (`c7i-flex.large`, 2 vCPU / 4 GB) and `bench-load`
(`m7i-flex.large`, 2 vCPU / 8 GB). Together they use 4 vCPUs, which fits a new account's default
quota of 5. Both are x86, so the images are built on the app node itself.

Flex instances guarantee 40% of each vCPU and can run at 100% most of the time, but not always.
That's fine below saturation, which is where the steady-state runs happen. For `make ceiling`,
watch `vmstat 5` on the app node; a non-zero `st` column means the numbers near the top are
partly the instance, not the instrumentation.

From your laptop, with the AWS CLI configured:

```sh
export AWS_REGION=ap-south-1   # pick one close to you and stick with it

SG=$(aws ec2 create-security-group --group-name bench --description "go-instrumentation-bench" \
  --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol -1 --source-group "$SG"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 \
  --cidr "$(curl -s https://checkip.amazonaws.com)/32"

aws ec2 create-key-pair --key-name bench --query KeyMaterial --output text > bench.pem && chmod 600 bench.pem
AMI=$(aws ssm get-parameter --query Parameter.Value --output text \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id)

for spec in bench-app:c7i-flex.large bench-load:m7i-flex.large; do
  aws ec2 run-instances --image-id "$AMI" --instance-type "${spec#*:}" --key-name bench \
    --security-group-ids "$SG" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${spec%%:*}}]" >/dev/null
done

aws ec2 describe-instances --filters Name=tag:Name,Values=bench-app,bench-load Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PublicIpAddress,PrivateIpAddress]' --output table
```

Then `ssh -i bench.pem ubuntu@<public ip>` into each one and follow [Setup](#setup) from step 2,
using the load node's **private** IP for `K3S_URL`. The security group already lets the two
instances talk to each other on every port, and nothing but SSH is open to the internet.

**Costs.** About $0.18/hour for both instances while they run, plus a few dollars a month for the
two 20 GB disks and public IPv4 addresses. Between sessions, stop them instead of deleting them:
disks, k3s and the images survive, and private IPs stay the same.

```sh
IDS=$(aws ec2 describe-instances --filters Name=tag:Name,Values=bench-app,bench-load \
  --query 'Reservations[].Instances[].InstanceId' --output text)
aws ec2 stop-instances --instance-ids $IDS    # end of session
aws ec2 start-instances --instance-ids $IDS   # next session
aws ec2 terminate-instances --instance-ids $IDS && aws ec2 delete-security-group --group-id "$SG"   # done for good
```

Set a billing alarm or AWS Budget at, say, $20 before the first run. On the Free plan you can't
be charged past the credit, but the account closes when the credit runs out.

## Commands

`make help` lists everything. The ones you'll use:

| Command | What it does |
|---|---|
| `make cluster` | local k3d cluster with registry, images imported, Jaeger deployed |
| `make tilt V=<variant>` | live dev loop |
| `make coverage V=<variant>` / `make coverage-all` | span and trace-context check |
| `make startup V=<variant>` / `make startup-all` | startup time, time to first span, untraced requests |
| `make ceiling V=<variant>` / `make ceiling-all` | highest rate that holds the p99 limit |
| `make run V=<variant>` | warmup, measured run, one CSV row |
| `make all` | `ROUNDS` × every variant, rotating order, then the report |
| `make report` | medians per variant compared with baseline |
| `make test` / `make lint` | service test; gofmt, go vet for both builds, shellcheck |
| `make clean` | delete the local cluster |

Knobs, as env vars or make variables: `RATE` (requests/s, default 200), `DURATION` (3m),
`WARMUP` (30s), `ROUNDS` (3), `PROFILE` (0 or 1), `STARTUP_WINDOW` (seconds of probing, 20),
`CEILING_RATES` (rates to step through), `CEILING_STEP` (30s), `CEILING_P99_MS` (25).

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
