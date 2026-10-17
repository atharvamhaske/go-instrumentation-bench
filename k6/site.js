// Launcher runs: the same request path against one or more site variants (conduit-<variant>)
// at once. Each scenario is named after its variant, so the `scenario` label splits the series.
//   TARGETS   comma-separated variants, e.g. "otelc" or "baseline,otelc"
//   SHAPE     steady | ramp | spike
//   RATE      peak req/s per variant
//   DURATION  seconds
import { getArticle, tokens } from './lib.js';

const TARGETS = (__ENV.TARGETS || 'baseline').split(',');
const SHAPE = __ENV.SHAPE || 'steady';
const RATE = Number(__ENV.RATE || 100);
const SECS = Number(__ENV.DURATION || 30);

function stages() {
  const s = (secs, target) => ({ duration: `${Math.max(1, Math.round(secs))}s`, target });
  if (SHAPE === 'ramp') return [s(SECS, RATE)];
  // spike: 10% load, a jump to full load for the middle fifth, then back down.
  const low = Math.max(1, Math.round(RATE / 10));
  return [s(SECS * 0.4, low), s(1, RATE), s(SECS * 0.2, RATE), s(1, low), s(SECS * 0.4, low)];
}

function scenario(variant) {
  const common = {
    exec: 'hit',
    env: { BASE: `http://conduit-${variant}:8080` },
    timeUnit: '1s',
    preAllocatedVUs: 20,
    maxVUs: 400,
  };
  if (SHAPE === 'steady') return { ...common, executor: 'constant-arrival-rate', rate: RATE, duration: `${SECS}s` };
  return { ...common, executor: 'ramping-arrival-rate', startRate: SHAPE === 'ramp' ? 0 : Math.max(1, Math.round(RATE / 10)), stages: stages() };
}

export const options = {
  discardResponseBodies: true,
  scenarios: Object.fromEntries(TARGETS.map((v) => [v, scenario(v)])),
};

export function setup() {
  return { tokens: tokens() };
}

export function hit(data) {
  getArticle(__ENV.BASE, data.tokens);
}
