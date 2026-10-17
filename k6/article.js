// Open-model load on one request path: GET /api/articles/{slug}.
// A fixed arrival rate keeps offered load identical across variants; a slower variant shows
// up as higher latency or dropped iterations instead of silently receiving less traffic.
import { getArticle, tokens } from './lib.js';

const BASE = __ENV.BASE_URL || 'http://conduit:8080';

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    article: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 200),
      timeUnit: '1s',
      duration: __ENV.DURATION || '3m',
      preAllocatedVUs: 50,
      maxVUs: 500,
    },
  },
};

export function setup() {
  return { tokens: tokens() };
}

export default function (data) {
  getArticle(BASE, data.tokens);
}

export function handleSummary(d) {
  const m = d.metrics;
  const dur = m.http_req_duration.values;
  const out = {
    reqs: m.http_reqs.values.count,
    rps: m.http_reqs.values.rate,
    failed: m.http_req_failed.values.rate,
    dropped: m.dropped_iterations ? m.dropped_iterations.values.count : 0,
    p50_ms: dur['p(50)'],
    p95_ms: dur['p(95)'],
    p99_ms: dur['p(99)'],
  };
  return { stdout: `\nRESULT ${JSON.stringify(out)}\n` };
}
