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
# Env: RATE (req/s, default 200), DURATION (3m), WARMUP (30s), ROUNDS (3), PROFILE (0|1),
#      JWT_SECRET (bench-secret), SKIP_DEPLOY (0|1)
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

deploy() {
  local v=$1
  log "deploying $v"
  k delete deploy conduit --ignore-not-found --wait >/dev/null
  k wait --for=delete pod -l app=conduit --timeout=120s >/dev/null 2>&1 || true
  if [[ $v == goauto ]]; then
    k apply -f k8s/app-goauto.yaml >/dev/null
  else
    sed "s/__VARIANT__/$v/g" k8s/app.yaml | k apply -f - >/dev/null
  fi
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

  curl -sS "http://localhost:26686/api/traces/$trace" | jq -r --arg parent "$parent" '
    (.data[0].spans // []) as $s
    | def tag($sp; $k): ($sp.tags[] | select(.key == $k) | .value) // "";
      def par($sp): ($sp.references[0].spanID // "-");
      ($s | map(select(tag(.; "span.kind") == "server"))) as $srv
    | "spans: \($s | length)",
      ($s | sort_by(.startTime)[]
        | "  \(.operationName)  kind=\(tag(.; "span.kind"))  id=\(.spanID)  parent=\(par(.))  \(.duration)us",
          "      attrs: \([.tags[].key | select(startswith("otel.") or startswith("span.") or . == "internal.span.format" | not)] | join(", "))"),
      "check: incoming traceparent honored      \(if ($srv | length) == 1 and par($srv[0]) == $parent then "PASS" else "FAIL" end)",
      "check: db spans are children of server   \(if ($srv | length) == 1 and ($s | map(select(tag(.; "span.kind") == "client")) | length) > 0 and all($s[] | select(tag(.; "span.kind") == "client"); par(.) == $srv[0].spanID) then "PASS" else "FAIL" end)"'
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
  *) sed -n "2,15p" "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
