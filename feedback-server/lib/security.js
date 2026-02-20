const { consumeIdempotencyKey } = require('./store');
const crypto = require('crypto');

const WINDOW_MS = 60 * 1000;
const DEFAULT_LIMIT = 60;
const limits = new Map();
const IDEM_TTL_SECONDS = 60 * 60 * 24 * 3;
const SESSION_TTL_SECONDS = 60 * 60 * 8;

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
  const keyId = (req.headers?.['x-api-key-id'] || '').toString().trim();
  const keyRaw = (req.headers?.['x-api-key'] || '').toString().trim();
  const keyFingerprint = keyId || (keyRaw ? crypto.createHash('sha256').update(keyRaw).digest('hex').slice(0, 12) : '');
  if (typeof forwarded === 'string' && forwarded.trim()) {
    const ip = forwarded.split(',')[0].trim();
    return keyFingerprint ? `${ip}:${keyFingerprint}` : ip;
  }
  const ip = req.socket?.remoteAddress || 'unknown';
  return keyFingerprint ? `${ip}:${keyFingerprint}` : ip;
}

function configuredKeys(singleName, multipleName) {
  const single = (process.env[singleName] || '').trim();
  const multiple = (process.env[multipleName] || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  return multiple.length ? multiple : (single ? [single] : []);
}

function matchesConfiguredKey(configured, incoming, incomingKeyId) {
  return configured.some((entry) => {
    if (entry.includes(':')) {
      const [kid, key] = entry.split(':');
      if (!kid || !key) return false;
      if (incomingKeyId && incomingKeyId !== kid) return false;
      return incoming === key;
    }
    return incoming === entry;
  });
}

function requireKey(req, res, configured, errorCode = 'unauthorized') {
  if (!configured.length) return true;

  const incoming = (req.headers?.['x-api-key'] || '').toString().trim();
  const incomingKeyId = (req.headers?.['x-api-key-id'] || '').toString().trim();
  if (!incoming) {
    res.status(401).json({ ok: false, error: errorCode });
    return false;
  }

  const matches = matchesConfiguredKey(configured, incoming, incomingKeyId);
  if (matches) return true;
  res.status(401).json({ ok: false, error: errorCode });
  return false;
}

function requireWriteApiKey(req, res) {
  const configured = configuredKeys('FEEDBACK_API_KEY', 'FEEDBACK_API_KEYS');
  return requireKey(req, res, configured, 'unauthorized');
}

function requireReadApiKey(req, res) {
  const allowPublic = (process.env.ALLOW_PUBLIC_DASHBOARD || '').trim().toLowerCase() === 'true';
  const configured = configuredKeys('FEEDBACK_READ_API_KEY', 'FEEDBACK_READ_API_KEYS');
  if (!configured.length) {
    if (allowPublic) return true;
    res.status(401).json({ ok: false, error: 'dashboard_key_not_configured' });
    return false;
  }
  return requireKey(req, res, configured, 'unauthorized');
}

const requireApiKey = requireWriteApiKey;

function base64url(input) {
  return Buffer.from(input).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function fromBase64url(input) {
  const normalized = input.replace(/-/g, '+').replace(/_/g, '/');
  const pad = normalized.length % 4 === 0 ? '' : '='.repeat(4 - (normalized.length % 4));
  return Buffer.from(normalized + pad, 'base64');
}

function getSessionSecret() {
  return (process.env.FEEDBACK_SESSION_SECRET || '').trim();
}

function getTokenSecret() {
  // Prefer a dedicated token secret. Fall back to session secret if set.
  return (process.env.FEEDBACK_TOKEN_SECRET || process.env.FEEDBACK_SESSION_SECRET || '').trim();
}

function createInstallToken(installId, now = Math.floor(Date.now() / 1000)) {
  const secret = getTokenSecret();
  if (!secret) return null;
  const payload = {
    kind: 'install',
    install_id: (installId || '').toString(),
    iat: now,
    exp: now + 60 * 60 * 24 * 7,
  };
  if (!payload.install_id) return null;
  const payloadStr = JSON.stringify(payload);
  const payloadB64 = base64url(payloadStr);
  const sig = crypto.createHmac('sha256', secret).update(payloadB64).digest('hex');
  return `${payloadB64}.${sig}`;
}

function verifyInstallToken(token, now = Math.floor(Date.now() / 1000)) {
  if (!token || typeof token !== 'string' || !token.includes('.')) return false;
  const secret = getTokenSecret();
  if (!secret) return false;
  const [payloadB64, signature] = token.split('.');
  if (!payloadB64 || !signature) return false;
  const expectedSig = crypto.createHmac('sha256', secret).update(payloadB64).digest('hex');
  const sigA = Buffer.from(signature);
  const sigB = Buffer.from(expectedSig);
  if (sigA.length !== sigB.length || !crypto.timingSafeEqual(sigA, sigB)) return false;
  try {
    const payload = JSON.parse(fromBase64url(payloadB64).toString('utf8'));
    if (payload.kind !== 'install') return false;
    if (typeof payload.install_id !== 'string' || !payload.install_id.trim()) return false;
    if (typeof payload.exp !== 'number' || payload.exp <= now) return false;
    return true;
  } catch (_) {
    return false;
  }
}

function bearerTokenFrom(req) {
  const auth = (req.headers?.authorization || '').toString().trim();
  if (!auth.toLowerCase().startsWith('bearer ')) return '';
  return auth.slice(7).trim();
}

function requireWriteAuth(req, res) {
  // If write keys are configured, require them.
  const configured = configuredKeys('FEEDBACK_API_KEY', 'FEEDBACK_API_KEYS');
  if (configured.length) return requireWriteApiKey(req, res);

  // Otherwise require a valid install token if token secret is configured.
  const secret = getTokenSecret();
  if (secret) {
    const token = bearerTokenFrom(req);
    if (verifyInstallToken(token)) return true;
    res.status(401).json({ ok: false, error: 'unauthorized' });
    return false;
  }

  // Dev fallback: allow.
  return true;
}

function createAdminSessionToken(now = Math.floor(Date.now() / 1000)) {
  const secret = getSessionSecret();
  if (!secret) return null;
  const payload = {
    role: 'admin',
    iat: now,
    exp: now + SESSION_TTL_SECONDS,
  };
  const payloadStr = JSON.stringify(payload);
  const payloadB64 = base64url(payloadStr);
  const sig = crypto.createHmac('sha256', secret).update(payloadB64).digest('hex');
  return `${payloadB64}.${sig}`;
}

function verifyAdminSessionToken(token, now = Math.floor(Date.now() / 1000)) {
  if (!token || typeof token !== 'string' || !token.includes('.')) return false;
  const secret = getSessionSecret();
  if (!secret) return false;
  const [payloadB64, signature] = token.split('.');
  if (!payloadB64 || !signature) return false;
  const expectedSig = crypto.createHmac('sha256', secret).update(payloadB64).digest('hex');
  const sigA = Buffer.from(signature);
  const sigB = Buffer.from(expectedSig);
  if (sigA.length !== sigB.length || !crypto.timingSafeEqual(sigA, sigB)) return false;
  try {
    const payload = JSON.parse(fromBase64url(payloadB64).toString('utf8'));
    if (payload.role !== 'admin') return false;
    if (typeof payload.exp !== 'number' || payload.exp <= now) return false;
    return true;
  } catch (_) {
    return false;
  }
}

function parseCookies(req) {
  const header = (req.headers?.cookie || '').toString();
  const out = {};
  if (!header) return out;
  for (const segment of header.split(';')) {
    const [k, ...rest] = segment.trim().split('=');
    if (!k) continue;
    out[k] = decodeURIComponent(rest.join('=') || '');
  }
  return out;
}

function isAdminSessionAuthenticated(req) {
  const cookies = parseCookies(req);
  const token = cookies.kc_admin_session || '';
  return verifyAdminSessionToken(token);
}

function shouldUseSecureCookie(req) {
  const env = (process.env.NODE_ENV || '').toLowerCase();
  if (env === 'production') return true;
  const proto = (req?.headers?.['x-forwarded-proto'] || '').toString().toLowerCase();
  if (proto === 'https') return true;
  return false;
}

function setAdminSessionCookie(res, req) {
  const token = createAdminSessionToken();
  if (!token) return false;
  const parts = [
    `kc_admin_session=${encodeURIComponent(token)}`,
    `Max-Age=${SESSION_TTL_SECONDS}`,
    'Path=/',
    'HttpOnly',
    'SameSite=Strict'
  ];
  if (shouldUseSecureCookie(req)) parts.splice(parts.length - 1, 0, 'Secure');
  const cookie = parts.join('; ');
  res.setHeader('Set-Cookie', cookie);
  return true;
}

function clearAdminSessionCookie(res, req) {
  const parts = [
    'kc_admin_session=',
    'Max-Age=0',
    'Path=/',
    'HttpOnly',
    'SameSite=Strict'
  ];
  if (shouldUseSecureCookie(req)) parts.splice(parts.length - 1, 0, 'Secure');
  const cookie = parts.join('; ');
  res.setHeader('Set-Cookie', cookie);
}

function requireDashboardAccess(req, res) {
  if (isAdminSessionAuthenticated(req)) return true;
  return requireReadApiKey(req, res);
}

function validateDashboardPassword(rawPassword) {
  const expected = (process.env.FEEDBACK_DASHBOARD_PASSWORD || '').trim();
  if (!expected) return false;
  const incoming = (rawPassword || '').toString().trim();
  if (!incoming) return false;
  const a = Buffer.from(incoming);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

async function checkRateLimit(req, res, route, limit = DEFAULT_LIMIT) {
  const limitByRoute = {
    analytics: Number(process.env.RATE_LIMIT_ANALYTICS_PER_MIN || 60),
    feedback: Number(process.env.RATE_LIMIT_FEEDBACK_PER_MIN || 30),
    stats: Number(process.env.RATE_LIMIT_STATS_PER_MIN || 60),
    kpis: Number(process.env.RATE_LIMIT_KPIS_PER_MIN || 40),
    kpi_export: Number(process.env.RATE_LIMIT_KPI_EXPORT_PER_MIN || 20),
    retention_export: Number(process.env.RATE_LIMIT_RETENTION_EXPORT_PER_MIN || 20),
    offline_save: Number(process.env.RATE_LIMIT_OFFLINE_SAVE_PER_MIN || 60),
  };
  const effectiveLimit = Number.isFinite(limitByRoute[route]) ? limitByRoute[route] : limit;
  const clientId = `${route}:${getClientId(req)}`;
  if (hasRedis()) {
    try {
      const count = await redisIncrWithWindow(`kc:rl:${clientId}`, Math.ceil(WINDOW_MS / 1000));
      if (count > effectiveLimit) {
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
  if (entry.count >= effectiveLimit) {
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

module.exports = {
  requireApiKey,
  requireWriteApiKey,
  requireReadApiKey,
  requireWriteAuth,
  bearerTokenFrom,
  createInstallToken,
  verifyInstallToken,
  requireDashboardAccess,
  validateDashboardPassword,
  isAdminSessionAuthenticated,
  setAdminSessionCookie,
  clearAdminSessionCookie,
  checkRateLimit,
  enforceIdempotency,
  idempotencyKeyFrom
};
