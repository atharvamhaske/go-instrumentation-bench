# API reference

The service under test is a read-only slice of the RealWorld "Conduit" API. It exposes two
endpoints. Only `GET /api/articles/{slug}` is load tested; `GET /api/tags` exists for manual
checks.

Base URL inside the cluster: `http://conduit.bench:8080`.

## Authentication

```
Authorization: Token <jwt>
```

RealWorld uses the `Token` scheme, not `Bearer`. The JWT must be:

- signed with HS256 using `JWT_SECRET` (default `bench-secret`). Any other `alg` is rejected.
- carrying an `exp` claim in the future. A token without `exp` is rejected.
- carrying `sub` as a positive user id in decimal, e.g. `"42"`. Seeded users are `1`–`2000`.

The signature is verified on every request. There is no cache, so verification cost is part of
the measured path.

Generate a token from a shell:

```sh
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
p=$(printf '{"sub":"42","exp":%d}' $(( $(date +%s) + 3600 )) | b64url)
s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac bench-secret -binary | b64url)
echo "$h.$p.$s"
```

k6 signs its own tokens the same way in `setup()` (see `k6/article.js`).

## Trace context

Every endpoint accepts a W3C `traceparent` header. Uninstrumented builds ignore it. Instrumented
builds should make the server span a child of the incoming span; `bench.sh coverage` checks this.

```
traceparent: 00-<32 hex trace id>-<16 hex parent span id>-01
```

## `GET /api/articles/{slug}`

Returns one article with its author, tags and favorite state for the calling user.

**Auth:** required.

**Path parameter:** `slug`. Seeded articles use `article-1` through `article-20000`.

**What it does, in order:**

1. Verifies the JWT.
2. Runs one query for the article, author, favorites count, whether the viewer favorited it, and
   whether the viewer follows the author.
3. Runs one query for the tag names, sorted.
4. Encodes JSON.

An instrumented build should emit three spans per request: one server span and two database
client spans.

**Example:**

```sh
curl -H "Authorization: Token $TOKEN" http://localhost:8080/api/articles/article-42
```

```http
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 1346
```

```json
{
  "article": {
    "slug": "article-42",
    "title": "Article 42",
    "description": "description",
    "body": "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ...",
    "tagList": ["tag06", "tag28", "tag48"],
    "createdAt": "2025-01-01T00:42:00.000Z",
    "updatedAt": "2025-01-01T00:42:00.000Z",
    "favorited": false,
    "favoritesCount": 16,
    "author": {
      "username": "user1033",
      "bio": "bio",
      "image": null,
      "following": false
    }
  }
}
```

`body` is about 1 KB in every seeded article; it is shortened above.

**Fields:**

| Field | Type | Notes |
|---|---|---|
| `slug`, `title`, `description`, `body` | string | |
| `tagList` | string[] | sorted by name, may be empty |
| `createdAt`, `updatedAt` | string | RFC 3339, UTC, exactly 3 fractional digits |
| `favorited` | bool | the caller favorited this article |
| `favoritesCount` | int | |
| `author.username` | string | |
| `author.bio`, `author.image` | string or null | |
| `author.following` | bool | the caller follows the author |

**Errors:**

| Status | When | Body |
|---|---|---|
| 401 | header missing, wrong scheme, bad signature, expired, no `exp`, bad `sub` | `{"errors":{"body":["unauthorized"]}}` |
| 404 | no article with that slug | `{"errors":{"body":["article not found"]}}` |
| 500 | database error (logged) | `{"errors":{"body":["internal error"]}}` |

## `GET /api/tags`

Returns all tag names, sorted.

**Auth:** none.

```sh
curl http://localhost:8080/api/tags
```

```json
{"tags": ["tag01", "tag02", "tag03", "..."]}
```

Seeded data has 50 tags, `tag01` to `tag50`.

## Other routes

Routing uses the Go 1.22 `ServeMux`, so:

- an unknown path gets `404` with the plain-text body `404 page not found`.
- a known path with the wrong method (e.g. `POST /api/tags`) gets `405`.

## Debug port

When `PPROF_ADDR` is set (the manifests set `:6060`), `net/http/pprof` is served on that address.
It is a separate listener, so profiling traffic never mixes with the request path.

```sh
kubectl -n bench port-forward deploy/conduit 6060
go tool pprof -http=: "http://localhost:6060/debug/pprof/profile?seconds=30"
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `8080` | HTTP listen port |
| `DB_PATH` | `/app/conduit.db` | SQLite file, opened read-only and immutable |
| `JWT_SECRET` | `bench-secret` | HS256 key |
| `PPROF_ADDR` | unset | pprof listen address, off when unset |
| `GOMAXPROCS` | number of CPUs | the manifests pin it to `2`; the DB pool size is `2 × GOMAXPROCS` |

The `manual` and `otelc` builds also read the standard OpenTelemetry SDK variables
(`OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`,
`OTEL_TRACES_SAMPLER`, `OTEL_PROPAGATORS`, `OTEL_METRICS_EXPORTER`, `OTEL_LOGS_EXPORTER`). In the
`goauto` variant the agent sidecar reads them instead, plus `OTEL_GO_AUTO_TARGET_EXE` and
`OTEL_GO_AUTO_INCLUDE_DB_STATEMENT`.

## Command line

```
conduit                 serve
conduit -seed <path>    write the deterministic seed database to <path> and exit
```

The image entrypoint wraps the binary in a small shell step:

1. If `START_GATE` is set, wait until `/tmp/go` exists (`bench.sh startup` creates it with
   `kubectl exec`).
2. Print `process-start`. The container runtime timestamps this line, which marks time zero.
3. `exec /app/conduit`, so the process keeps the `/app/conduit` path that the eBPF agent looks for.

## Data model

SQLite, created by `service/seed.go`. Timestamps are unix milliseconds.

```
users        (id PK, username UNIQUE, bio, image)
articles     (id PK, slug UNIQUE, author_id, title, description, body, created_at, updated_at)
tags         (id PK, name UNIQUE)
article_tags (article_id, tag_id)        PK (article_id, tag_id)
favorites    (user_id, article_id)       PK (user_id, article_id), index (article_id, user_id)
follows      (follower_id, followee_id)  PK (follower_id, followee_id)
```

Seed size: 2,000 users, 20,000 articles, 50 tags, about 49k article tags, 190k favorites and
38k follows. About 33 MB on disk. The random generator has a fixed seed, so every image build
produces the same data.

## Benchmark output: `results/results.csv`

One row per `bench.sh run`.

| Column | Meaning |
|---|---|
| `variant` | `baseline`, `manual`, `otelc` or `goauto` |
| `rate` | offered load, requests per second |
| `reqs` | requests completed in the measured window |
| `failed_rate` | share of requests with a non-2xx status or transport error (0–1) |
| `dropped` | k6 iterations that could not start because all VUs were busy. Above 0 means the service could not keep up |
| `p50_ms`, `p99_ms` | client-side latency from k6 |
| `app_cpu_ms_per_req` | CPU time of the `conduit` container divided by `reqs` |
| `agent_cpu_ms_per_req` | same for the `agent` sidecar (`goauto` only, 0 otherwise) |
| `total_cpu_ms_per_req` | sum of the two |
| `app_mem_mb`, `agent_mem_mb` | working set at the end of the run |
| `profiled` | `1` if a pprof profile was taken during the run; `report` skips these rows |
| `time` | UTC timestamp of the end of the run |

## Ceiling output: `results/ceiling.csv`

One row per step of `bench.sh ceiling`, including retried steps.

| Column | Meaning |
|---|---|
| `variant`, `rate`, `reqs`, `failed_rate`, `dropped`, `p50_ms`, `p99_ms` | as in `results.csv`, for that step |
| `p99_limit_ms` | `CEILING_P99_MS` used for the run |
| `pass` | `pass` if p99 ≤ limit, errors < 1% and dropped ≤ 1% of offered requests; otherwise `fail` |
| `time` | UTC timestamp |

The ceiling for a variant is the highest `rate` with `pass` before two consecutive `fail` rows.

## Startup output: `results/startup.csv`

One row per `bench.sh startup`.

| Column | Meaning |
|---|---|
| `variant` | as above |
| `startup_ms` | from the `process-start` log line to the `conduit listening` log line |
| `first_span_ms` | from `process-start` to the start time of the first server span. `-` if nothing was traced |
| `ok_requests` | probe requests answered with 200 during the window |
| `traced_requests` | of those, how many have a server span in Jaeger |
| `untraced_before_first_span` | answered requests sent before the first traced one |
| `time` | UTC timestamp |

Probe requests use trace id `<24 random hex><request number as 8 hex>` and parent span
`00f067aa0ba902b7`, and go to the pod IP directly, so readiness probes don't delay them.

## Launcher

`launcher/` serves the public site (`make site-up`, then the ALB on EKS). Standard library only.
Every accepted run becomes a k6 Job, and the visitor is redirected to the Grafana dashboard
filtered to that run.

| Route | What it does |
|---|---|
| `GET /` | redirects to `/run/` |
| `GET /run/` | list of variants and a link to the compare page |
| `GET /run/{variant}` | form for one variant: shape, rate, duration. Unknown variant: 404 |
| `POST /run/{variant}` | start a run against that variant |
| `GET /run/compare` | form with variant checkboxes |
| `POST /run/compare` | start a run against every checked variant at once (`variant` repeated) |
| `GET /api/state` | `{"busy": bool, "seconds_left": int, "run_id": "..."}` |
| `GET /healthz` | `ok`, used by the readiness probe and the ALB health check |

Form fields: `shape` = `steady` \| `ramp` \| `spike`; `rate` = `100` \| `250` \| `500` \| `1000` \|
`2000` (req/s per variant); `duration` = `15` \| `30` \| `60` (seconds). Anything else is a 400.

POST responses:

| Status | When |
|---|---|
| 303 | started; `Location` is `<GRAFANA_URL>/d/bench/bench?var-run_id=<id>&var-variant=<v>...` |
| 400 | invalid input, or `rate × variants` above `MAX_TOTAL` |
| 409 | another run is in progress (one at a time; the lock lasts `duration + 20s`) |
| 429 | this visitor already started `RUNS_PER_HOUR` runs in the last hour |
| 502 | the Kubernetes API refused the Job |

The visitor is identified by the **last** `X-Forwarded-For` entry, the one the ALB appends.
Earlier entries come from the client and can be forged. Run state is in memory, so the
launcher runs as exactly one replica.

The Job is named `k6-site-<run id>`, labelled `bench/run=site`, runs on the load node, is killed
after `duration + 120s` and deleted 10 minutes after it finishes. The launcher's service account
may only create, get and list Jobs in `bench`.

| Env | Default | Meaning |
|---|---|---|
| `ADDR` | `:8080` | listen address |
| `NAMESPACE` | `bench` | where Jobs are created |
| `K6_IMAGE` | `grafana/k6:1.8.2` | |
| `PROM_WRITE_URL` | `http://prometheus:9090/api/v1/write` | k6 remote-write target |
| `GRAFANA_URL` | `/grafana` | redirect prefix; the Ingress serves Grafana on the same host |
| `JWT_SECRET` | `bench-secret` | passed to k6 so its tokens verify |
| `MAX_TOTAL` | `2000` | cap on `rate × variants` |
| `RUNS_PER_HOUR` | `3` | per visitor |

## Site load script: `k6/site.js`

One scenario per target, named after the variant and aimed at `http://conduit-<variant>:8080`.
Each scenario is its own open-model arrival rate, so a slow variant can't slow down the others'
offered load.

| Env | Meaning |
|---|---|
| `TARGETS` | comma-separated variants |
| `SHAPE` | `steady`: constant `RATE`. `ramp`: 0 to `RATE` over the duration. `spike`: 10% of `RATE` for 40%, `RATE` for the middle 20%, back to 10% |
| `RATE` | peak req/s per variant |
| `DURATION` | seconds |

Metrics go to Prometheus through k6's `experimental-prometheus-rw` output with
`K6_PROMETHEUS_RW_TREND_STATS=p(50),p(95),p(99)`, pushed every 5s, tagged `run_id`. Series are
split by the `scenario` label (= variant). The request carries the tag
`name=/api/articles/{slug}` so every slug shares one series. Without it, k6 creates one series
per URL, more than 100k in a 30s run.
