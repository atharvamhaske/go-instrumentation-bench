// Open-model load on one request path: GET /api/articles/{slug}.
// A fixed arrival rate keeps offered load identical across variants; a slower variant shows
// up as higher latency or dropped iterations instead of silently receiving less traffic.
import http from 'k6/http';
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';

const BASE = __ENV.BASE_URL || 'http://conduit:8080';
const SECRET = __ENV.JWT_SECRET || 'bench-secret';
const USERS = 2000;
const ARTICLES = 20000;

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

const b64 = (s) => encoding.b64encode(s, 'rawurl');

function token(userId) {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = b64('{"alg":"HS256","typ":"JWT"}') + '.' +
    b64(JSON.stringify({ sub: String(userId), iat: now, exp: now + 86400 }));
  return unsigned + '.' + crypto.hmac('sha256', SECRET, unsigned, 'base64rawurl');
}

const hex = (n) => Array.from(new Uint8Array(crypto.randomBytes(n)), (b) => b.toString(16).padStart(2, '0')).join('');

export function setup() {
  return { tokens: Array.from({ length: 200 }, (_, i) => token(1 + Math.floor(i * USERS / 200))) };
}

export default function (data) {
  const slug = `article-${1 + Math.floor(Math.random() * ARTICLES)}`;
  http.get(`${BASE}/api/articles/${slug}`, {
    headers: {
      Authorization: `Token ${data.tokens[Math.floor(Math.random() * data.tokens.length)]}`,
      traceparent: `00-${hex(16)}-${hex(8)}-01`,
    },
  });
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
