package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

type fakeAPI struct {
	jobs []map[string]any
	fail bool
}

func (f *fakeAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.URL.Path != "/apis/batch/v1/namespaces/bench/jobs" {
		http.Error(w, "unexpected "+r.Method+" "+r.URL.Path, http.StatusNotFound)
		return
	}
	if f.fail {
		http.Error(w, "nope", http.StatusForbidden)
		return
	}
	var job map[string]any
	_ = json.NewDecoder(r.Body).Decode(&job)
	f.jobs = append(f.jobs, job)
	w.WriteHeader(http.StatusCreated)
}

func setup(t *testing.T) (*server, *fakeAPI, *time.Time) {
	t.Helper()
	api := &fakeAPI{}
	ts := httptest.NewServer(api)
	t.Cleanup(ts.Close)
	cfg := config{namespace: "bench", k6Image: "k6", promWrite: "http://p/w", jwtSecret: "s", grafanaURL: "/grafana", maxTotal: 2000, perHour: 3}
	s := newServer(cfg, &kube{base: ts.URL, client: ts.Client()})
	now := time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	return s, api, &now
}

func post(s *server, path, ip string, form url.Values) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.Header.Set("X-Forwarded-For", "6.6.6.6, "+ip)
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, r)
	return w
}

func form(rate, dur string, variants ...string) url.Values {
	return url.Values{"shape": {"spike"}, "rate": {rate}, "duration": {dur}, "variant": variants}
}

func TestStartCreatesJobAndRedirects(t *testing.T) {
	s, api, _ := setup(t)
	w := post(s, "/run/otelc", "1.1.1.1", form("250", "30"))
	if w.Code != http.StatusSeeOther {
		t.Fatalf("status %d: %s", w.Code, w.Body)
	}
	loc, _ := url.Parse(w.Header().Get("Location"))
	if loc.Path != "/grafana/d/bench/bench" || loc.Query().Get("var-variant") != "otelc" || loc.Query().Get("var-run_id") == "" {
		t.Fatalf("redirect %s", loc)
	}
	if len(api.jobs) != 1 {
		t.Fatalf("jobs created: %d", len(api.jobs))
	}
	b, _ := json.Marshal(api.jobs[0])
	for _, want := range []string{
		`"name":"TARGETS","value":"otelc"`, `"name":"SHAPE","value":"spike"`, `"name":"RATE","value":"250"`,
		`"name":"DURATION","value":"30"`, `"run_id=` + loc.Query().Get("var-run_id") + `"`, `"activeDeadlineSeconds":150`,
		`"bench/load":"true"`,
	} {
		if !strings.Contains(string(b), want) {
			t.Errorf("job missing %s\n%s", want, b)
		}
	}
}

func TestOneAtATimeThenPerVisitorLimit(t *testing.T) {
	s, api, now := setup(t)
	if w := post(s, "/run/manual", "1.1.1.1", form("100", "15")); w.Code != http.StatusSeeOther {
		t.Fatalf("first run: %d", w.Code)
	}
	if w := post(s, "/run/manual", "2.2.2.2", form("100", "15")); w.Code != http.StatusConflict {
		t.Fatalf("second run while busy: %d", w.Code)
	}
	for range 2 {
		*now = now.Add(time.Minute)
		if w := post(s, "/run/manual", "1.1.1.1", form("100", "15")); w.Code != http.StatusSeeOther {
			t.Fatalf("run after previous finished: %d", w.Code)
		}
	}
	*now = now.Add(time.Minute)
	if w := post(s, "/run/manual", "1.1.1.1", form("100", "15")); w.Code != http.StatusTooManyRequests {
		t.Fatalf("4th run in an hour: %d", w.Code)
	}
	// The spoofable first X-Forwarded-For entry is the same; only the last one counts.
	if w := post(s, "/run/manual", "3.3.3.3", form("100", "15")); w.Code != http.StatusSeeOther {
		t.Fatalf("other visitor: %d", w.Code)
	}
	*now = now.Add(time.Hour)
	if w := post(s, "/run/manual", "1.1.1.1", form("100", "15")); w.Code != http.StatusSeeOther {
		t.Fatalf("after an hour: %d", w.Code)
	}
	if len(api.jobs) != 5 {
		t.Fatalf("jobs created: %d", len(api.jobs))
	}
}

func TestValidation(t *testing.T) {
	s, api, _ := setup(t)
	for name, tc := range map[string]struct {
		path string
		f    url.Values
		code int
	}{
		"unknown variant":   {"/run/nope", form("100", "15"), http.StatusNotFound},
		"odd rate":          {"/run/otelc", form("999", "15"), http.StatusBadRequest},
		"odd duration":      {"/run/otelc", form("100", "600"), http.StatusBadRequest},
		"bad shape":         {"/run/otelc", url.Values{"shape": {"x"}, "rate": {"100"}, "duration": {"15"}}, http.StatusBadRequest},
		"over total cap":    {"/run/compare", form("1000", "15", "baseline", "manual", "otelc"), http.StatusBadRequest},
		"duplicate variant": {"/run/compare", form("100", "15", "otelc", "otelc"), http.StatusBadRequest},
		"no variants":       {"/run/compare", form("100", "15"), http.StatusBadRequest},
	} {
		if w := post(s, tc.path, "1.1.1.1", tc.f); w.Code != tc.code {
			t.Errorf("%s: status %d, want %d", name, w.Code, tc.code)
		}
	}
	if len(api.jobs) != 0 {
		t.Fatalf("jobs created for invalid input: %d", len(api.jobs))
	}
}

func TestCompareAndAPIFailure(t *testing.T) {
	s, api, _ := setup(t)
	api.fail = true
	if w := post(s, "/run/compare", "1.1.1.1", form("500", "15", "baseline", "goauto")); w.Code != http.StatusBadGateway {
		t.Fatalf("api failure: %d", w.Code)
	}
	api.fail = false
	w := post(s, "/run/compare", "1.1.1.1", form("500", "15", "baseline", "goauto"))
	if w.Code != http.StatusSeeOther {
		t.Fatalf("compare: %d %s", w.Code, w.Body)
	}
	loc, _ := url.Parse(w.Header().Get("Location"))
	if got := loc.Query()["var-variant"]; len(got) != 2 {
		t.Fatalf("redirect variants %v", got)
	}
	b, _ := json.Marshal(api.jobs[0])
	if !strings.Contains(string(b), `"name":"TARGETS","value":"baseline,goauto"`) {
		t.Fatalf("job targets: %s", b)
	}
}
