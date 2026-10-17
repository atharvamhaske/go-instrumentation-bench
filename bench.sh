#!/usr/bin/env bash
# Usage: ./bench.sh <command> [variant]
#   images                 build bench/conduit:{baseline,manual,otelc}
#   local-cluster          single-node k3d cluster (app + load roles on one node)
#   import-k3s             import images into a k3s node (run on the app node)
#   infra                  namespace + Jaeger
#   coverage <variant>     one traced request: spans, attributes, parent/child, traceparent
#                          (SKIP_DEPLOY=1 checks whatever is already running, e.g. under Tilt)
#   run <variant>          warmup, then measured run; appends results/results.csv
#   all                    ROUNDS x every variant in rotating order, then report
#   report                 medians per variant vs baseline
#   startup <variant>      process start -> listening, -> first span, requests served untraced
#   ceiling <variant>      step RATE up until p99 / errors / drops cross a limit; results/ceiling.csv
# Env: RATE (req/s, default 200), DURATION (3m), WARMUP (30s), ROUNDS (3), PROFILE (0|1),
#      JWT_SECRET (bench-secret), SKIP_DEPLOY (0|1), STARTUP_WINDOW (probe seconds, 20),
#      CEILING_RATES ("100 200 ... 4800"), CEILING_STEP (30s), CEILING_P99_MS (25)
set -euo pipefail
cd "$(dirname "$0")"

NS=bench
RATE=${RATE:-200}
DURATION=${DURATION:-3m}
WARMUP=${WARMUP:-30s}
ROUNDS=${ROUNDS:-3}
PROFILE=${PROFILE:-0}
SECRET=${JWT_SECRET:-bench-secret}
VARIANTS=(baseline manual otelc goauto)
CSV=results/results.csv

k() { kubectl -n "$NS" "$@"; }
log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }

images() {
  for v in baseline manual otelc; do
    docker build --build-arg VARIANT="$v" -t "bench/conduit:$v" service
  done
}

local_cluster() {
  k3d cluster create bench --registry-create bench-registry --k3s-arg '--disable=traefik@server:0' --wait
  kubectl label node --all bench/app=true bench/load=true --overwrite
  k3d image import -c bench bench/conduit:baseline bench/conduit:manual bench/conduit:otelc
  infra
}

import_k3s() {
  docker save bench/conduit:baseline bench/conduit:manual bench/conduit:otelc | sudo k3s ctr images import -
}

infra() {
  kubectl apply -f k8s/infra.yaml
  k rollout status deploy/jaeger --timeout=180s
}

manifest() {
  if [[ $1 == goauto ]]; then cat k8s/app-goauto.yaml; else sed "s/__VARIANT__/$1/g" k8s/app.yaml; fi
}

undeploy() {
  k delete deploy conduit --ignore-not-found --wait >/dev/null
  k wait --for=delete pod -l app=conduit --timeout=120s >/dev/null 2>&1 || true
}

deploy() {
  local v=$1
  log "deploying $v"
  undeploy
  manifest "$v" | k apply -f - >/dev/null
  k rollout status deploy/conduit --timeout=180s >/dev/null
  # The eBPF agent attaches after the app starts; don't send traffic before its probes load.
  sleep 10
}

restart_jaeger() {
  k rollout restart deploy/jaeger >/dev/null
  k rollout status deploy/jaeger --timeout=180s >/dev/null
}

# k6_run <rate> <duration>: prints k6's RESULT JSON.
k6_run() {
  k delete job k6 --ignore-not-found --wait >/dev/null
  k create configmap k6-script --from-file=k6/article.js --dry-run=client -o yaml | k apply -f - >/dev/null
  sed -e "s/__RATE__/$1/" -e "s/__DURATION__/$2/" k8s/k6-job.yaml | k apply -f - >/dev/null
  local s=""
  until [[ -n $s ]]; do
    sleep 5
    s=$(k get job k6 -o jsonpath='{.status.succeeded}{.status.failed}')
  done
  if [[ $(k get job k6 -o jsonpath='{.status.succeeded}') != 1 ]]; then
    k logs job/k6 >&2
    return 1
  fi
  k logs job/k6 | sed -n 's/^RESULT //p'
}

# Cumulative CPU (ns) and working set per container of the conduit pod, from the kubelet.
# The kubelet refreshes these every ~10s, so callers wait for the pod to go idle first.
snapshot() {
  local pod node
  pod=$(k get pod -l app=conduit -o jsonpath='{.items[0].metadata.name}')
  node=$(k get pod "$pod" -o jsonpath='{.spec.nodeName}')
  kubectl get --raw "/api/v1/nodes/$node/proxy/stats/summary" | jq -c --arg pod "$pod" \
    '[.pods[] | select(.podRef.name == $pod) | .containers[]
      | {key: .name, value: {cpu_ns: .cpu.usageCoreNanoSeconds, mem: .memory.workingSetBytes}}] | from_entries'
}

profile() {
  local v=$1 pod out
  pod=$(k get pod -l app=conduit -o jsonpath='{.items[0].metadata.name}')
  out="results/profile-$v-$(date +%Y%m%dT%H%M%S).pb.gz"
  kubectl -n "$NS" port-forward "$pod" 16060:6060 >/dev/null 2>&1 &
  local pf=$!
  sleep 2
  curl -fsS -o "$out" "http://localhost:16060/debug/pprof/profile?seconds=30" && log "profile: $out" || true
  kill "$pf" 2>/dev/null || true
}

run() {
  local v=$1
  deploy "$v"
  restart_jaeger
  log "$v: warmup $WARMUP at $RATE req/s"
  k6_run "$RATE" "$WARMUP" >/dev/null
  sleep 20
  local before after result
  before=$(snapshot)
  # Profiled runs are marked in the CSV: the profiler's own cost lands in the numbers.
  [[ $PROFILE == 1 ]] && (sleep 30 && profile "$v") &
  log "$v: measuring $DURATION at $RATE req/s"
  result=$(k6_run "$RATE" "$DURATION")
  wait
  sleep 20
  after=$(snapshot)

  mkdir -p results
  [[ -f $CSV ]] || echo "variant,rate,reqs,failed_rate,dropped,p50_ms,p99_ms,app_cpu_ms_per_req,agent_cpu_ms_per_req,total_cpu_ms_per_req,app_mem_mb,agent_mem_mb,profiled,time" >"$CSV"
  jq -rn --arg v "$v" --arg rate "$RATE" --arg prof "$PROFILE" \
    --argjson r "$result" --argjson a "$before" --argjson b "$after" '
    def r3: . * 1000 | round / 1000;
    def cpu(c): (($b[c].cpu_ns // 0) - ($a[c].cpu_ns // 0)) / 1e6 / $r.reqs;
    def mem(c): ($b[c].mem // 0) / 1048576 | r3;
    [$v, $rate, $r.reqs, ($r.failed | r3), $r.dropped, ($r.p50_ms | r3), ($r.p99_ms | r3),
     (cpu("conduit") | r3), (cpu("agent") | r3), (cpu("conduit") + cpu("agent") | r3),
     mem("conduit"), mem("agent"), $prof, (now | todate)] | map(tostring) | join(",")' | tee -a "$CSV"
}

# ceiling <variant>: step the offered rate up until p99, errors or dropped iterations cross a limit.
# The last passing rate is the variant's capacity at that latency target.
ceiling() {
  local v=$1 rate result verdict last_ok=0
  local rates=${CEILING_RATES:-"100 200 400 800 1200 1600 2400 3200 4800"}
  local step=${CEILING_STEP:-30s} p99_max=${CEILING_P99_MS:-25}
  local out=results/ceiling.csv
  mkdir -p results
  [[ -f $out ]] || echo "variant,rate,reqs,failed_rate,dropped,p50_ms,p99_ms,p99_limit_ms,pass,time" >"$out"

  deploy "$v"
  log "$v: warmup $WARMUP"
  k6_run "${rates%% *}" "$WARMUP" >/dev/null
  local attempt
  for rate in $rates; do
    # A failed step is retried once: one transient spike shouldn't set the capacity number.
    for attempt in 1 2; do
      restart_jaeger
      log "$v: $rate req/s for $step (p99 limit ${p99_max}ms, attempt $attempt)"
      result=$(k6_run "$rate" "$step")
      # Pass: p99 under the limit, under 1% errors, under 1% of offered requests dropped.
      verdict=$(jq -r --argjson lim "$p99_max" \
        'if .p99_ms <= $lim and .failed < 0.01 and .dropped <= 0.01 * (.reqs + .dropped) then "pass" else "fail" end' <<<"$result")
      jq -rn --arg v "$v" --arg rate "$rate" --arg lim "$p99_max" --arg verdict "$verdict" --argjson r "$result" '
        def r3: . * 1000 | round / 1000;
        [$v, $rate, $r.reqs, ($r.failed | r3), $r.dropped, ($r.p50_ms | r3), ($r.p99_ms | r3), $lim, $verdict, (now | todate)]
        | map(tostring) | join(",")' | tee -a "$out"
      [[ $verdict == pass ]] && break
    done
    [[ $verdict == pass ]] || break
    last_ok=$rate
  done
  log "$v: ceiling ${last_ok} req/s at p99 <= ${p99_max}ms"
}

all() {
  for ((round = 0; round < ROUNDS; round++)); do
    for i in "${!VARIANTS[@]}"; do
      run "${VARIANTS[$(((i + round) % ${#VARIANTS[@]}))]}"
    done
  done
  report
}

report() {
  [[ -s $CSV ]] || { log "no results yet: run ./bench.sh run <variant> first"; return 1; }
  jq -Rrn '
    def median: sort | .[length / 2 | floor];
    def pct($x; $base): if $base > 0 then (($x / $base - 1) * 100 | round | tostring) + "%" else "-" end;
    [inputs | split(",") | select(.[0] != "variant" and .[12] == "0")]
    | group_by(.[0])
    | map({v: .[0][0], n: length,
           p99: (map(.[6] | tonumber) | median),
           cpu: (map(.[9] | tonumber) | median),
           agent: (map(.[8] | tonumber) | median)})
    | (map(select(.v == "baseline"))[0] // {p99: 0, cpu: 0}) as $b
    | ["variant", "runs", "p99_ms", "p99_vs_base", "cpu_ms/req", "of_which_agent", "cpu_vs_base"],
      (.[] | [.v, .n, .p99, pct(.p99; $b.p99), .cpu, .agent, pct(.cpu; $b.cpu)])
    | map(tostring) | join("\t")' "$CSV" | column -t -s $'\t'
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

jwt() {
  local h p
  h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  p=$(printf '{"sub":"%s","exp":%d}' "$1" $(($(date +%s) + 3600)) | b64url)
  printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$SECRET" -binary | b64url)"
}

# startup <variant>: process start -> listening, process start -> first server span, and how many
# requests were answered before tracing began. All timestamps come from the app node's clock:
# container runtime log timestamps and span start times.
startup() {
  local v=$1 pod ip prefix probe_out
  STARTUP_WINDOW=${STARTUP_WINDOW:-20}

  if ! k get pod prober >/dev/null 2>&1; then
    k run prober --image=curlimages/curl:8.16.0 --restart=Never \
      --overrides='{"spec":{"nodeSelector":{"bench/load":"true"}}}' --command -- sleep infinity >/dev/null
  fi
  k wait --for=condition=Ready pod/prober --timeout=180s >/dev/null
  restart_jaeger

  log "deploying $v behind a start gate"
  undeploy
  manifest "$v" \
    | perl -pe 's/^(\s*)- \{name: GOMAXPROCS, value: "2"\}\n/$&$1- {name: START_GATE, value: "1"}\n/' \
    | k apply -f - >/dev/null
  k wait --for=jsonpath='{.status.phase}'=Running pod -l app=conduit --timeout=180s >/dev/null
  pod=$(k get pod -l app=conduit -o jsonpath='{.items[0].metadata.name}')
  ip=$(k get pod "$pod" -o jsonpath='{.status.podIP}')
  prefix=$(openssl rand -hex 12)
  probe_out=$(mktemp)

  log "$v: probing $ip every ~50ms for ${STARTUP_WINDOW}s, then opening the gate"
  # Request i carries trace id <prefix><i as 8 hex digits>, so a span maps back to its request.
  # shellcheck disable=SC2016
  k exec prober -- env IP="$ip" PREFIX="$prefix" TOKEN="$(jwt 42)" WINDOW="$STARTUP_WINDOW" sh -c '
    i=0; end=$(( $(date +%s) + WINDOW ))
    while [ "$(date +%s)" -lt "$end" ]; do
      i=$((i + 1))
      c=$(curl -s -o /dev/null -m 1 -w "%{http_code}" -H "Authorization: Token $TOKEN" \
        -H "traceparent: 00-$PREFIX$(printf %08x $i)-00f067aa0ba902b7-01" "http://$IP:8080/api/articles/article-1")
      echo "$i $c"
      sleep 0.05
    done' >"$probe_out" &
  local prober_pid=$!
  sleep 1
  k exec "$pod" -c conduit -- touch /tmp/go
  wait "$prober_pid"
  sleep 10 # batch span processors flush every 5s

  kubectl -n "$NS" port-forward svc/jaeger 26686:16686 >/dev/null 2>&1 &
  trap 'kill $(jobs -p) 2>/dev/null' EXIT
  sleep 2
  # Look up every answered request by its known trace id (Jaeger v2 dropped the v1 search API).
  local spans i
  spans=$(awk '$2 == 200 { print $1 }' "$probe_out" | while read -r i; do
    curl -s "http://localhost:26686/api/traces/$prefix$(printf %08x "$i")" | jq -c --argjson i "$i" \
      '.data[0].spans[]? | select(any(.tags[]; .key == "span.kind" and .value == "server")) | {i: $i, t: (.startTime / 1000)}'
  done | jq -sc 'sort_by(.i)')

  mkdir -p results
  [[ -f results/startup.csv ]] || echo "variant,startup_ms,first_span_ms,ok_requests,traced_requests,untraced_before_first_span,time" >results/startup.csv
  k logs "$pod" -c conduit --timestamps | jq -Rrn --arg v "$v" \
    --rawfile probe "$probe_out" --argjson spans "$spans" '
    def ms: capture("^(?<s>[^.Z]+)(\\.(?<f>[0-9]+))?Z") as $m
      | (($m.s + "Z") | fromdateiso8601) * 1000 + ((($m.f // "") + "000000000")[:9] | tonumber / 1e6);
    def r1: . * 10 | round / 10;
    [inputs | select(length > 0) | (index(" ")) as $i | {t: (.[:$i] | ms), msg: .[$i + 1:]}] as $logs
    | ($logs | map(select(.msg == "process-start"))[0].t) as $t0
    | ($logs | map(select(.msg | test("conduit listening")))[0].t) as $tl
    | [$probe | split("\n")[] | select(length > 0) | split(" ") | select(.[1] == "200") | .[0] | tonumber] as $ok
    | ($spans[0] // null) as $first
    | {variant: $v,
       startup_ms: (($tl - $t0) | r1),
       first_span_ms: (if $first then ($first.t - $t0 | r1) else "-" end),
       ok_requests: ($ok | length),
       traced_requests: ($spans | length),
       untraced_before_first_span: (if $first then ($ok | map(select(. < $first.i)) | length) else ($ok | length) end)}
    | ., ([.variant, .startup_ms, .first_span_ms, .ok_requests, .traced_requests, .untraced_before_first_span, (now | todate)]
          | map(tostring) | join(",") | "CSV " + .)' >"$probe_out.result"
  grep -v '^CSV ' "$probe_out.result"
  sed -n 's/^CSV //p' "$probe_out.result" >>results/startup.csv
  rm -f "$probe_out" "$probe_out.result"
}

coverage() {
  local v=$1
  [[ ${SKIP_DEPLOY:-0} == 1 ]] || deploy "$v"
  kubectl -n "$NS" port-forward svc/conduit 18080:8080 >/dev/null 2>&1 &
  kubectl -n "$NS" port-forward svc/jaeger 26686:16686 >/dev/null 2>&1 &
  trap 'kill $(jobs -p) 2>/dev/null' EXIT
  sleep 3

  local trace parent code
  trace=$(openssl rand -hex 16)
  parent=$(openssl rand -hex 8)
  code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Token $(jwt 42)" \
    -H "traceparent: 00-$trace-$parent-01" http://localhost:18080/api/articles/article-42)
  log "$v: GET /api/articles/article-42 -> $code, trace $trace, sent parent span $parent"
  sleep 10 # batch span processors flush every 5s

  curl -sS "http://localhost:26686/api/traces/$trace" | jq -r --arg parent "$parent" --arg v "$v" '
    (.data[0].spans // []) as $s
    | def tag($sp; $k): ($sp.tags[] | select(.key == $k) | .value) // "";
      def par($sp): ($sp.references[0].spanID // "-");
      ($s | map(select(tag(.; "span.kind") == "server"))) as $srv
    | if $v == "baseline" then
        "spans: \($s | length)",
        "check: baseline emits no telemetry       \(if ($s | length) == 0 then "PASS" else "FAIL" end)"
      else
    "spans: \($s | length)",
      ($s | sort_by(.startTime)[]
        | "  \(.operationName)  kind=\(tag(.; "span.kind"))  id=\(.spanID)  parent=\(par(.))  \(.duration)us",
          "      attrs: \([.tags[].key | select(startswith("otel.") or startswith("span.") or . == "internal.span.format" | not)] | join(", "))"),
      "check: incoming traceparent honored      \(if ($srv | length) == 1 and par($srv[0]) == $parent then "PASS" else "FAIL" end)",
      "check: db spans are children of server   \(if ($srv | length) == 1 and ($s | map(select(tag(.; "span.kind") == "client")) | length) > 0 and all($s[] | select(tag(.; "span.kind") == "client"); par(.) == $srv[0].spanID) then "PASS" else "FAIL" end)"
      end'
}

cmd=${1:-}
shift || true
case $cmd in
  images) images ;;
  local-cluster) local_cluster ;;
  import-k3s) import_k3s ;;
  infra) infra ;;
  coverage) coverage "${1:?variant}" ;;
  run) run "${1:?variant}" ;;
  all) all ;;
  report) report ;;
  startup) startup "${1:?variant}" ;;
  ceiling) ceiling "${1:?variant}" ;;
  *) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 1 ;;
esac
