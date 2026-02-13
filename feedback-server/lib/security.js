const { consumeIdempotencyKey } = require('./store');

const WINDOW_MS = 60 * 1000;
const DEFAULT_LIMIT = 120;
const limits = new Map();
const IDEM_TTL_SECONDS = 60 * 60 * 24 * 3;

const redisRestUrl = (process.env.UPSTASH_REDIS_REST_URL || process.env.REDIS_REST_URL || '').trim();
const redisRestToken = (process.env.UPSTASH_REDIS_REST_TOKEN || process.env.REDIS_REST_TOKEN || '').trim();

function hasRedis() {
  return !!(redisRestUrl && redisRestToken);
}

async function redisRequest(path) {
  const res = await fetch(`${redisRestUrl}${path}`, {
    headers: {
      Authorization: `Bearer ${redisRestToken}`,
    },
  });
  if (!res.ok) throw new Error(`redis_http_${res.status}`);
  return res.json();
}

async function redisIncrWithWindow(key, windowSeconds) {
  const incr = await redisRequest(`/incr/${encodeURIComponent(key)}`);
  const count = Number(incr?.result ?? 0);
  if (count === 1) {
    await redisRequest(`/expire/${encodeURIComponent(key)}/${windowSeconds}`);
  }
  return count;
}

async function redisSetNx(key, ttlSeconds) {
  const value = Date.now().toString();
  const q = `?NX=true&EX=${ttlSeconds}`;
  const out = await redisRequest(`/set/${encodeURIComponent(key)}/${encodeURIComponent(value)}${q}`);
  return out?.result === 'OK';
}

function getClientId(req) {
  const forwarded = req.headers?.['x-forwarded-for'];
  if (typeof forwarded === 'string' && forwarded.trim()) {
    return forwarded.split(',')[0].trim();
  }
  return req.socket?.remoteAddress || 'unknown';
}

function requireApiKey(req, res) {
  const single = (process.env.FEEDBACK_API_KEY || '').trim();
  const multiple = (process.env.FEEDBACK_API_KEYS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  const configured = multiple.length ? multiple : (single ? [single] : []);
  if (!configured.length) return true;

  const incoming = (req.headers?.['x-api-key'] || '').toString().trim();
  const incomingKeyId = (req.headers?.['x-api-key-id'] || '').toString().trim();
  if (!incoming) {
    res.status(401).json({ ok: false, error: 'unauthorized' });
    return false;
  }

  const matches = configured.some((entry) => {
    if (entry.includes(':')) {
      const [kid, key] = entry.split(':');
      if (!kid || !key) return false;
      if (incomingKeyId && incomingKeyId !== kid) return false;
      return incoming === key;
    }
    return incoming === entry;
  });
  if (matches) return true;
  res.status(401).json({ ok: false, error: 'unauthorized' });
  return false;
}

async function checkRateLimit(req, res, route, limit = DEFAULT_LIMIT) {
  const clientId = `${route}:${getClientId(req)}`;
  if (hasRedis()) {
    try {
      const count = await redisIncrWithWindow(`kc:rl:${clientId}`, Math.ceil(WINDOW_MS / 1000));
      if (count > limit) {
        res.status(429).json({ ok: false, error: 'rate_limited' });
        return false;
      }
      return true;
    } catch (e) {
      // Fall back to in-memory limiter if Redis is unavailable.
      console.error('[security] redis rate-limit fallback', e.message);
    }
  }

  const now = Date.now();
  const entry = limits.get(clientId);
  if (!entry || now - entry.windowStart >= WINDOW_MS) {
    limits.set(clientId, { windowStart: now, count: 1 });
    return true;
  }
  if (entry.count >= limit) {
    res.status(429).json({ ok: false, error: 'rate_limited' });
    return false;
  }
  entry.count += 1;
  limits.set(clientId, entry);
  return true;
}

async function enforceIdempotency(res, key) {
  if (!key) return true;
  if (hasRedis()) {
    try {
      const accepted = await redisSetNx(`kc:idem:${key}`, IDEM_TTL_SECONDS);
      if (accepted) return true;
      res.status(200).json({ ok: true, deduped: true });
      return false;
    } catch (e) {
      console.error('[security] redis idempotency fallback', e.message);
    }
  }
  const accepted = await consumeIdempotencyKey(key);
  if (accepted) return true;
  res.status(200).json({ ok: true, deduped: true });
  return false;
}

function idempotencyKeyFrom(req, body, fallbackPrefix) {
  const headerKey = (req.headers?.['x-idempotency-key'] || '').toString().trim();
  if (headerKey) return `${fallbackPrefix}:${headerKey}`;
  if (typeof body?.id === 'string' && body.id.trim()) return `${fallbackPrefix}:id:${body.id.trim()}`;
  if (typeof body?.install_id === 'string' && typeof body?.timestamp === 'string' && typeof body?.event === 'string') {
    return `${fallbackPrefix}:analytics:${body.install_id}:${body.event}:${body.timestamp}`;
  }
  return '';
}

module.exports = { requireApiKey, checkRateLimit, enforceIdempotency, idempotencyKeyFrom };
