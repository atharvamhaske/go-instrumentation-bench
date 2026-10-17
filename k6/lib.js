// Shared by article.js (benchmark runs) and site.js (launcher runs).
import http from 'k6/http';
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';

const SECRET = __ENV.JWT_SECRET || 'bench-secret';
const USERS = 2000;
const ARTICLES = 20000;

const b64 = (s) => encoding.b64encode(s, 'rawurl');

function token(userId) {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = b64('{"alg":"HS256","typ":"JWT"}') + '.' +
    b64(JSON.stringify({ sub: String(userId), iat: now, exp: now + 86400 }));
  return unsigned + '.' + crypto.hmac('sha256', SECRET, unsigned, 'base64rawurl');
}

const hex = (n) => Array.from(new Uint8Array(crypto.randomBytes(n)), (b) => b.toString(16).padStart(2, '0')).join('');

export function tokens() {
  return Array.from({ length: 200 }, (_, i) => token(1 + Math.floor(i * USERS / 200)));
}

// One GET /api/articles/{slug} with a random user and a fresh traceparent.
export function getArticle(base, tokens) {
  const slug = `article-${1 + Math.floor(Math.random() * ARTICLES)}`;
  http.get(`${base}/api/articles/${slug}`, {
    headers: {
      Authorization: `Token ${tokens[Math.floor(Math.random() * tokens.length)]}`,
      traceparent: `00-${hex(16)}-${hex(8)}-01`,
    },
    // One series for the route instead of one per slug.
    tags: { name: '/api/articles/{slug}' },
  });
}
