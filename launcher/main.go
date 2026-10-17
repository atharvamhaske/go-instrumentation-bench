// Command launcher serves the public "run a load test" pages. Each accepted run becomes a k6 Job
// (k6/site.js) against one or more site variants, and the visitor is sent to the live Grafana
// dashboard filtered to that run.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var (
	variants  = []string{"baseline", "manual", "otelc", "goauto"}
	shapes    = []string{"steady", "ramp", "spike"}
	rates     = []int{100, 250, 500, 1000, 2000}
	durations = []int{15, 30, 60}
)

var variantInfo = map[string]string{
	"baseline": "no telemetry",
	"manual":   "OpenTelemetry SDK by hand: otelhttp + otelsql",
	"otelc":    "compile-time injection with otelc",
	"goauto":   "eBPF agent sidecar (Go auto-instrumentation)",
}

type config struct {
	namespace  string
	k6Image    string
	promWrite  string
	jwtSecret  string
	grafanaURL string
	maxTotal   int
	perHour    int
}

type server struct {
	cfg  config
	kube *kube
	now  func() time.Time

	// ponytail: run state lives in memory, so the launcher must run as a single replica.
	// Upgrade path: list Jobs labelled bench/run=site and count the active ones.
	mu        sync.Mutex
	busyUntil time.Time
	runID     string
	hits      map[string][]time.Time
}

func main() {
	cfg := config{
		namespace:  env("NAMESPACE", "bench"),
		k6Image:    env("K6_IMAGE", "grafana/k6:1.8.2"),
		promWrite:  env("PROM_WRITE_URL", "http://prometheus:9090/api/v1/write"),
		jwtSecret:  env("JWT_SECRET", "bench-secret"),
		grafanaURL: env("GRAFANA_URL", "/grafana"),
		maxTotal:   envInt("MAX_TOTAL", 2000),
		perHour:    envInt("RUNS_PER_HOUR", 3),
	}
	k, err := inCluster()
	if err != nil {
		log.Fatal(err)
	}
	srv := &http.Server{
		Addr:              env("ADDR", ":8080"),
		Handler:           newServer(cfg, k).routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()
	log.Printf("launcher listening on %s", srv.Addr)
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func newServer(cfg config, k *kube) *server {
	return &server{cfg: cfg, kube: k, now: time.Now, hits: map[string][]time.Time{}}
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/run/", http.StatusFound)
	})
	mux.HandleFunc("GET /run/{$}", s.index)
	mux.HandleFunc("GET /run/compare", func(w http.ResponseWriter, r *http.Request) { s.form(w, nil, "", http.StatusOK) })
	mux.HandleFunc("POST /run/compare", s.startCompare)
	mux.HandleFunc("GET /run/{variant}", func(w http.ResponseWriter, r *http.Request) {
		if v := r.PathValue("variant"); slices.Contains(variants, v) {
			s.form(w, []string{v}, "", http.StatusOK)
			return
		}
		http.NotFound(w, r)
	})
	mux.HandleFunc("POST /run/{variant}", s.startOne)
	mux.HandleFunc("GET /api/state", s.state)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	return mux
}

func (s *server) index(w http.ResponseWriter, _ *http.Request) {
	render(w, http.StatusOK, pageData{Index: true, Info: variantInfo, Variants: variants, Busy: s.busyFor(), Grafana: s.cfg.grafanaURL})
}

func (s *server) form(w http.ResponseWriter, fixed []string, msg string, status int) {
	render(w, status, pageData{
		Fixed: fixed, Variants: variants, Info: variantInfo, Shapes: shapes, Rates: rates, Durations: durations,
		MaxTotal: s.cfg.maxTotal, Error: msg, Busy: s.busyFor(), Grafana: s.cfg.grafanaURL,
	})
}

func (s *server) startOne(w http.ResponseWriter, r *http.Request) {
	v := r.PathValue("variant")
	if !slices.Contains(variants, v) {
		http.NotFound(w, r)
		return
	}
	s.start(w, r, []string{v}, []string{v})
}

func (s *server) startCompare(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	s.start(w, r, r.PostForm["variant"], nil)
}

type run struct {
	targets  []string
	shape    string
	rate     int
	duration int
}

func (s *server) parse(r *http.Request, targets []string) (run, error) {
	rn := run{targets: targets, shape: r.PostFormValue("shape")}
	rn.rate, _ = strconv.Atoi(r.PostFormValue("rate"))
	rn.duration, _ = strconv.Atoi(r.PostFormValue("duration"))
	switch {
	case len(targets) == 0:
		return rn, errors.New("pick at least one variant")
	case len(targets) > len(variants):
		return rn, errors.New("too many variants")
	case !slices.Contains(shapes, rn.shape):
		return rn, errors.New("unknown shape")
	case !slices.Contains(rates, rn.rate):
		return rn, errors.New("unknown rate")
	case !slices.Contains(durations, rn.duration):
		return rn, errors.New("unknown duration")
	case rn.rate*len(targets) > s.cfg.maxTotal:
		return rn, fmt.Errorf("%d variants x %d req/s is over the %d req/s total cap", len(targets), rn.rate, s.cfg.maxTotal)
	}
	seen := map[string]bool{}
	for _, t := range targets {
		if !slices.Contains(variants, t) || seen[t] {
			return rn, fmt.Errorf("bad variant %q", t)
		}
		seen[t] = true
	}
	return rn, nil
}

func (s *server) start(w http.ResponseWriter, r *http.Request, targets, fixed []string) {
	rn, err := s.parse(r, targets)
	if err != nil {
		s.form(w, fixed, err.Error(), http.StatusBadRequest)
		return
	}
	id, status, msg := s.admit(r, rn)
	if status != 0 {
		s.form(w, fixed, msg, status)
		return
	}
	http.Redirect(w, r, s.dashboard(id, rn.targets), http.StatusSeeOther)
}

// admit applies the one-at-a-time and per-visitor limits and creates the Job. The lock is held
// across the API call so two visitors can't both start a run. A non-zero status means rejected.
func (s *server) admit(r *http.Request, rn run) (string, int, string) {
	ip := clientIP(r)
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if now.Before(s.busyUntil) {
		return "", http.StatusConflict, fmt.Sprintf("a test is already running, try again in %ds", int(s.busyUntil.Sub(now).Seconds())+1)
	}
	recent := slices.DeleteFunc(s.hits[ip], func(t time.Time) bool { return now.Sub(t) > time.Hour })
	s.hits[ip] = recent
	if len(recent) >= s.cfg.perHour {
		wait := time.Hour - now.Sub(recent[0])
		return "", http.StatusTooManyRequests, fmt.Sprintf("limit is %d tests per hour, next one in %dm", s.cfg.perHour, int(wait.Minutes())+1)
	}

	id := newRunID(now)
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err := s.kube.createJob(ctx, s.cfg.namespace, s.job(id, rn)); err != nil {
		log.Printf("run %s: %v", id, err)
		return "", http.StatusBadGateway, "could not start the test"
	}
	log.Printf("run %s: %v %s %d req/s %ds from %s", id, rn.targets, rn.shape, rn.rate, rn.duration, ip)
	s.busyUntil = now.Add(time.Duration(rn.duration+20) * time.Second)
	s.runID = id
	s.hits[ip] = append(recent, now)
	return id, 0, ""
}

func (s *server) dashboard(id string, targets []string) string {
	q := url.Values{"var-run_id": {id}, "var-variant": targets, "from": {"now-1m"}, "to": {"now"}, "refresh": {"5s"}}
	return s.cfg.grafanaURL + "/d/bench/bench?" + q.Encode()
}

func (s *server) state(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	left := max(0, int(s.busyUntil.Sub(s.now()).Seconds()))
	id := s.runID
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"busy": left > 0, "seconds_left": left, "run_id": id})
}

func (s *server) busyFor() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return max(0, int(s.busyUntil.Sub(s.now()).Seconds()))
}

func (s *server) job(id string, rn run) map[string]any {
	envs := []map[string]string{
		{"name": "TARGETS", "value": strings.Join(rn.targets, ",")},
		{"name": "SHAPE", "value": rn.shape},
		{"name": "RATE", "value": strconv.Itoa(rn.rate)},
		{"name": "DURATION", "value": strconv.Itoa(rn.duration)},
		{"name": "JWT_SECRET", "value": s.cfg.jwtSecret},
		{"name": "K6_PROMETHEUS_RW_SERVER_URL", "value": s.cfg.promWrite},
		{"name": "K6_PROMETHEUS_RW_TREND_STATS", "value": "p(50),p(95),p(99)"},
		{"name": "K6_PROMETHEUS_RW_PUSH_INTERVAL", "value": "5s"},
	}
	return map[string]any{
		"apiVersion": "batch/v1",
		"kind":       "Job",
		"metadata": map[string]any{
			"name":   "k6-site-" + id,
			"labels": map[string]string{"bench/run": "site", "bench/run-id": id},
		},
		"spec": map[string]any{
			"backoffLimit":            0,
			"ttlSecondsAfterFinished": 600,
			"activeDeadlineSeconds":   rn.duration + 120,
			"template": map[string]any{
				"metadata": map[string]any{"labels": map[string]string{"bench/run": "site"}},
				"spec": map[string]any{
					"restartPolicy": "Never",
					"nodeSelector":  map[string]string{"bench/load": "true"},
					"containers": []map[string]any{{
						"name":         "k6",
						"image":        s.cfg.k6Image,
						"args":         []string{"run", "--quiet", "-o", "experimental-prometheus-rw", "--tag", "run_id=" + id, "/scripts/site.js"},
						"env":          envs,
						"volumeMounts": []map[string]string{{"name": "scripts", "mountPath": "/scripts"}},
					}},
					"volumes": []map[string]any{{"name": "scripts", "configMap": map[string]string{"name": "k6-script"}}},
				},
			},
		},
	}
}

func newRunID(now time.Time) string {
	b := make([]byte, 2)
	_, _ = rand.Read(b)
	return now.UTC().Format("0102-150405") + "-" + hex.EncodeToString(b)
}

// clientIP trusts only the last X-Forwarded-For entry: the one the ALB appended itself.
// Earlier entries are whatever the client sent.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		return strings.TrimSpace(parts[len(parts)-1])
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// kube is the one Kubernetes API call the launcher needs, without client-go.
type kube struct {
	base      string
	tokenFile string
	client    *http.Client
}

func inCluster() (*kube, error) {
	const sa = "/var/run/secrets/kubernetes.io/serviceaccount/"
	ca, err := os.ReadFile(sa + "ca.crt")
	if err != nil {
		return nil, fmt.Errorf("not running in a cluster: %w", err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(ca)
	return &kube{
		base:      "https://" + net.JoinHostPort(os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")),
		tokenFile: sa + "token",
		client:    &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}}},
	}, nil
}

func (k *kube) createJob(ctx context.Context, ns string, job map[string]any) error {
	body, err := json.Marshal(job)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, k.base+"/apis/batch/v1/namespaces/"+ns+"/jobs", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if k.tokenFile != "" {
		// Re-read every call: projected service account tokens rotate.
		token, err := os.ReadFile(k.tokenFile)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	}
	resp, err := k.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		var buf bytes.Buffer
		_, _ = buf.ReadFrom(resp.Body)
		return fmt.Errorf("create job: %s: %s", resp.Status, strings.TrimSpace(buf.String()))
	}
	return nil
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if n, err := strconv.Atoi(os.Getenv(k)); err == nil {
		return n
	}
	return def
}

type pageData struct {
	Index     bool
	Fixed     []string
	Variants  []string
	Info      map[string]string
	Shapes    []string
	Rates     []int
	Durations []int
	MaxTotal  int
	Error     string
	Busy      int
	Grafana   string
}

func render(w http.ResponseWriter, status int, d pageData) {
	var buf bytes.Buffer
	if err := page.Execute(&buf, d); err != nil {
		log.Printf("render: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_, _ = buf.WriteTo(w)
}

var page = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Go instrumentation bench</title>
<style>
body{font:16px/1.5 system-ui,sans-serif;max-width:44rem;margin:2rem auto;padding:0 1rem;color:#111}
a{color:#0b5fff}fieldset{border:1px solid #ccc;border-radius:6px;margin:0 0 1rem}label{display:inline-block;margin:.2rem 1rem .2rem 0}
button{font:inherit;padding:.5rem 1.2rem;border:0;border-radius:6px;background:#111;color:#fff;cursor:pointer}
.err{background:#fde8e8;padding:.6rem 1rem;border-radius:6px}.busy{background:#fff6dd;padding:.6rem 1rem;border-radius:6px}
small{color:#555}
</style></head><body>
<h1><a href="/run/" style="color:inherit;text-decoration:none">Go instrumentation bench</a></h1>
<p>One Go service (GET /api/articles/{slug}, SQLite, JWT) built four ways. Send it load and watch latency and CPU per request live in Grafana.</p>
{{if .Busy}}<p class="busy">A test is running now ({{.Busy}}s left). <a href="{{.Grafana}}/d/bench/bench">Watch it</a>.</p>{{end}}
{{if .Error}}<p class="err">{{.Error}}</p>{{end}}
{{if .Index}}
<ul>{{range .Variants}}<li><a href="/run/{{.}}">{{.}}</a>: <small>{{index $.Info .}}</small></li>{{end}}</ul>
<p><a href="/run/compare">Compare variants head to head</a></p>
{{else}}
<form method="post">
{{if .Fixed}}<h2>{{index .Fixed 0}}</h2><p><small>{{index .Info (index .Fixed 0)}}</small></p>
{{else}}<fieldset><legend>Variants</legend>{{range .Variants}}<label><input type="checkbox" name="variant" value="{{.}}" checked> {{.}}</label>{{end}}</fieldset>{{end}}
<fieldset><legend>Shape</legend>{{range $i, $s := .Shapes}}<label><input type="radio" name="shape" value="{{$s}}"{{if eq $i 0}} checked{{end}}> {{$s}}</label>{{end}}</fieldset>
<fieldset><legend>Rate (req/s per variant)</legend>{{range $i, $r := .Rates}}<label><input type="radio" name="rate" value="{{$r}}"{{if eq $i 0}} checked{{end}}> {{$r}}</label>{{end}}</fieldset>
<fieldset><legend>Duration</legend>{{range $i, $d := .Durations}}<label><input type="radio" name="duration" value="{{$d}}"{{if eq $i 1}} checked{{end}}> {{$d}}s</label>{{end}}</fieldset>
<p><small>One test at a time, 3 per hour per visitor, {{.MaxTotal}} req/s total across variants.</small></p>
<button>Start</button>
</form>
{{end}}
</body></html>
`))
