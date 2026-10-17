# Runbook

How to run a benchmark session from start to finish, how to tell whether the numbers are any
good, and what to do when something breaks. The README explains why the setup looks the way it
does; this file is just the steps.

## 0. Before you start

- [ ] `kubectl config current-context` points at the cluster you expect.
- [ ] Nodes are labelled: `kubectl get nodes -L bench/app,bench/load`. One node has
      `bench/app=true` and one has `bench/load=true`. Locally it's the same node with both.
- [ ] Images exist on the app node: `bench/conduit:baseline`, `:manual`, `:otelc`
      (`make images`, then `make cluster` locally or `./bench.sh import-k3s` on k3s).
- [ ] Jaeger is up: `kubectl -n bench get deploy jaeger`.
- [ ] Nothing else is running on the app node: `kubectl get pods -A -o wide --field-selector spec.nodeName=<app-node>`.
      Only `conduit` and the system pods should show.
- [ ] `results/results.csv` is either empty or only holds runs from this same setup. Move old
      files away; `report` mixes every row it finds.

## 1. Check coverage first

```sh
make coverage-all
```

Expected for `manual`, `otelc` and `goauto`:

```
spans: 3
check: incoming traceparent honored      PASS
check: db spans are children of server   PASS
```

`baseline` should show `spans: 0` and two `FAIL` lines. That is correct.

If an instrumented variant shows fewer than 3 spans or a `FAIL`, stop here. A cost number for a
variant that doesn't capture the same work isn't comparable. See
[Troubleshooting](#troubleshooting).

Save the output; it's the "coverage" slide.

## 2. Find the rate

Instrumentation overhead only makes sense below saturation. At saturation you're measuring
queueing.

```sh
for r in 200 400 800 1600; do RATE=$r DURATION=1m WARMUP=20s ./bench.sh run baseline; done
```

Look for the first rate where `p99_ms` jumps by several times, or `dropped` is above 0. Use about
half of that rate for the session. Then delete those rows from `results/results.csv`.

## 3. Run the session

```sh
RATE=<chosen> ROUNDS=5 DURATION=3m make all
```

One round is four runs. Each run takes about `WARMUP + DURATION + 1.5 min` (deploy, Jaeger
restart, idle waits), so about 5 minutes with the defaults. 5 rounds take about 100 minutes. The order of variants
rotates every round.

Then, separately, profile the variants you want to explain:

```sh
PROFILE=1 RATE=<chosen> DURATION=2m make run V=goauto
go tool pprof -http=: results/profile-goauto-*.pb.gz
```

Profiled rows are marked `profiled=1` and left out of `make report`. Compare them with the
unprofiled rows to show what the profiler itself costs.

## 4. Check the numbers before you trust them

Open `results/results.csv` and check every row:

| Check | Bad sign | What to do |
|---|---|---|
| `failed_rate` | above 0 | read `kubectl -n bench logs deploy/conduit`, fix, rerun |
| `dropped` | above 0 | rate is too high for that variant. Either lower `RATE` for every variant, or report it as the finding |
| `reqs` | far below `RATE × DURATION` | same as `dropped` |
| `p99_ms` spread across rounds of one variant | more than ~20% | noisy node. Add rounds, check CPU steal (below), or move to dedicated CPU |
| `agent_cpu_ms_per_req` | 0 for `goauto` | the agent wasn't running. Check its logs |
| `app_cpu_ms_per_req` | 0 for any variant | the kubelet stats weren't read. See Troubleshooting |

CPU steal on a VM (the hypervisor giving your vCPU to someone else):

```sh
# on the app node, during a run
vmstat 5    # "st" column. Consistently above 1–2 means shared CPU is skewing the numbers
```

## 5. Report

```sh
make report
```

```
variant   runs  p99_ms  p99_vs_base  cpu_ms/req  of_which_agent  cpu_vs_base
baseline  5     ...
```

Values are medians across rounds. `cpu_ms/req` already includes the agent. Keep the CSV with
the slides, along with the k6 version, Go version, node type and `RATE`.

## 6. Tear down

Local:

```sh
make clean
```

Cloud: delete the droplets or VMs when you're done. Hourly billing stops only when the machine
is destroyed, not when it's powered off (DigitalOcean bills powered-off droplets too).

## Troubleshooting

### `curl: (52) Empty reply from server` during `coverage`

A port-forward from an earlier run still holds port 18080 and points at a pod that no longer
exists.

```sh
pgrep -fl port-forward
pkill -f "kubectl -n bench port-forward"
```

### `goauto` shows 0 spans

Check the agent:

```sh
kubectl -n bench logs deploy/conduit -c agent
```

- **Stuck on `Polling for process`:** `shareProcessNamespace: true` is missing from the pod spec,
  or `OTEL_GO_AUTO_TARGET_EXE` doesn't match the binary path (`/app/conduit`).
- **Errors about offsets or unsupported Go version:** the binary was built with a Go version that
  agent v0.24.0 has no offsets for. The Dockerfile pins `golang:1.26.1`; keep it there, or move to
  an agent release that lists your Go version.
- **Permission or BPF errors:** the agent needs `privileged: true` and `runAsUser: 0`. On some
  hosts `/sys/kernel/btf/vmlinux` is missing; check with `ls /sys/kernel/btf/vmlinux` on the node.
- **`instrumentation loaded successfully` but still nothing:** the agent attaches a few seconds
  after the app starts. Requests sent before that aren't traced. `deploy` waits 10s; raise it if
  your node is slow.

### `manual` or `otelc` show 0 spans

- `kubectl -n bench logs deploy/conduit` for exporter errors, e.g. `connection refused` to
  `jaeger:4318`. Jaeger must be running before the app.
- The batch processor flushes every 5s. `coverage` waits 10s. If Jaeger is slow to index, rerun.

### `ErrImageNeverPull` or `ImagePullBackOff` for `bench/conduit:*`

The image isn't on the node that runs the pod.

- Local: `k3d image import -c bench bench/conduit:baseline bench/conduit:manual bench/conduit:otelc`
- k3s: run `./bench.sh import-k3s` **on the app node**, not on the load node.
- Check: `sudo k3s ctr images ls | grep conduit` on the node.

### `app_cpu_ms_per_req` is 0 or negative

`snapshot` reads `/api/v1/nodes/<node>/proxy/stats/summary`. Test it:

```sh
kubectl get --raw "/api/v1/nodes/$(kubectl get nodes -o name | head -1 | cut -d/ -f2)/proxy/stats/summary" | jq '.pods | length'
```

An RBAC error means your kubeconfig user can't read node proxy stats; use the admin kubeconfig.
A negative value means the pod restarted during the run (CPU counters reset). Check
`kubectl -n bench get pods` for restarts, usually an OOM kill.

### k6 Job fails

```sh
kubectl -n bench logs job/k6
```

- `dial tcp: lookup conduit`: the Service is missing. Redeploy the variant.
- Many `request timeout` errors: rate far above capacity; lower `RATE`.

### Jaeger OOMKilled

At high rates its in-memory store fills up within one run. `bench.sh run` restarts Jaeger before
every run, which clears it. If it still dies during a single run, raise its memory limit in
`k8s/infra.yaml`. This doesn't affect the app's numbers unless the restart happens mid-run;
exporters retry and drop on failure.

### `k3d cluster create` fails right after `make clean`

The old containers are still being removed. Wait a few seconds and run `make cluster` again.

### Oracle Cloud: agent node never joins

Oracle's Ubuntu images ship iptables rules that drop most inbound traffic, on top of the VCN
security list. Open both:

```sh
sudo iptables -I INPUT -s 10.0.0.0/16 -j ACCEPT && sudo netfilter-persistent save
```

and add an ingress rule for the subnet CIDR in the VCN security list.
