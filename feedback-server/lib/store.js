const BLOB_PATH = 'kc/data.json';
// 0 means "no cap" (persist everything). Dashboard endpoints should page/slice.
const MAX_ANALYTICS = Number.parseInt(process.env.MAX_ANALYTICS || '0', 10) || 0;
const MAX_FEEDBACK = Number.parseInt(process.env.MAX_FEEDBACK || '0', 10) || 0;
const MAX_SAVED_URLS = Number.parseInt(process.env.MAX_SAVED_URLS || '0', 10) || 0;
const MAX_ISSUES = Number.parseInt(process.env.MAX_ISSUES || '0', 10) || 0;
const MAX_IDEMPOTENCY_KEYS = Number.parseInt(process.env.MAX_IDEMPOTENCY_KEYS || '2000', 10) || 2000;
const crypto = require('crypto');

async function getBlobClient() {
  try {
    const { put, list } = await import('@vercel/blob');
    return { put, list };
  } catch (e) {
    return null;
  }
}

async function readData() {
  const client = await getBlobClient();
  if (!client || !process.env.BLOB_READ_WRITE_TOKEN) {
    return { analytics: [], feedback: [], saved_urls: [], issues: [], idempotency: [] };
  }
  try {
    const { list } = client;
    const { blobs } = await list({ prefix: 'kc/' });
    const dataBlob = blobs.find((b) => b.pathname === BLOB_PATH);
    if (!dataBlob?.url) return { analytics: [], feedback: [], saved_urls: [], issues: [], idempotency: [] };
    const res = await fetch(dataBlob.url);
    if (!res.ok) return { analytics: [], feedback: [], saved_urls: [], issues: [], idempotency: [] };
    const raw = await res.json();
    const json = decryptStoredPayload(raw);
    return {
      analytics: Array.isArray(json.analytics) ? json.analytics : [],
      feedback: Array.isArray(json.feedback) ? json.feedback : [],
      saved_urls: Array.isArray(json.saved_urls) ? json.saved_urls : [],
      issues: Array.isArray(json.issues) ? json.issues : [],
      idempotency: Array.isArray(json.idempotency) ? json.idempotency : [],
    };
  } catch (e) {
    console.error('[store] read', e);
    return { analytics: [], feedback: [], saved_urls: [], issues: [], idempotency: [] };
  }
}

async function writeData(data) {
  const client = await getBlobClient();
  if (!client || !process.env.BLOB_READ_WRITE_TOKEN) {
    throw new Error('blob_token_missing');
  }
  const { put } = client;
  const encrypted = encryptStoredPayload(data);
  await put(BLOB_PATH, JSON.stringify(encrypted), {
    access: 'public',
    addRandomSuffix: false,
    contentType: 'application/json',
    allowOverwrite: true,
  });
}

function getCipherKey() {
  const raw = (process.env.FEEDBACK_DATA_ENCRYPTION_KEY || process.env.FEEDBACK_API_KEY || '').trim();
  if (!raw) return null;
  return crypto.createHash('sha256').update(raw).digest();
}

function encryptStoredPayload(data) {
  const key = getCipherKey();
  if (!key) return data;
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const plaintext = Buffer.from(JSON.stringify(data), 'utf8');
  const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  return {
    v: 1,
    alg: 'aes-256-gcm',
    iv: iv.toString('base64'),
    tag: tag.toString('base64'),
    data: encrypted.toString('base64')
  };
}

function decryptStoredPayload(raw) {
  if (!raw || typeof raw !== 'object' || raw.v !== 1 || !raw.iv || !raw.tag || !raw.data) {
    return raw || {};
  }
  const key = getCipherKey();
  if (!key) return {};
  try {
    const iv = Buffer.from(raw.iv, 'base64');
    const tag = Buffer.from(raw.tag, 'base64');
    const encrypted = Buffer.from(raw.data, 'base64');
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAuthTag(tag);
    const decrypted = Buffer.concat([decipher.update(encrypted), decipher.final()]);
    return JSON.parse(decrypted.toString('utf8'));
  } catch (e) {
    console.error('[store] decrypt', e);
    return {};
  }
}

async function appendAnalytics(payload) {
  const data = await readData();
  data.analytics.unshift({ ...payload, _at: new Date().toISOString() });
  if (MAX_ANALYTICS > 0) data.analytics.splice(MAX_ANALYTICS);
  await writeData(data);
}

async function appendFeedback(payload) {
  const data = await readData();
  data.feedback.unshift({ ...payload, _at: new Date().toISOString() });
  if (MAX_FEEDBACK > 0) data.feedback.splice(MAX_FEEDBACK);
  await writeData(data);
}

async function appendIssue(payload) {
  const data = await readData();
  data.issues.unshift({ ...payload, _at: new Date().toISOString() });
  if (MAX_ISSUES > 0) data.issues.splice(MAX_ISSUES);
  await writeData(data);
}

function canonicalizeUrl(rawUrl) {
  try {
    const u = new URL(rawUrl);
    u.hash = '';
    u.hostname = u.hostname.toLowerCase();
    return u.toString();
  } catch (e) {
    return null;
  }
}

async function appendSavedUrl(payload) {
  const data = await readData();
  const next = {
    id: payload.id || `${Date.now()}`,
    url: payload.url,
    title: payload.title || null,
    source: payload.source || 'browser',
    _at: new Date().toISOString(),
  };
  const canonical = canonicalizeUrl(next.url);
  data.saved_urls = data.saved_urls.filter((entry) => {
    const existing = canonicalizeUrl(entry.url || '');
    return !canonical || existing !== canonical;
  });
  data.saved_urls.unshift(next);
  if (MAX_SAVED_URLS > 0) data.saved_urls.splice(MAX_SAVED_URLS);
  await writeData(data);
  return next;
}

async function consumeIdempotencyKey(key) {
  if (!key) return true;
  const data = await readData();
  const now = new Date().toISOString();
  data.idempotency = data.idempotency.filter((entry) => {
    if (!entry || typeof entry.key !== 'string' || typeof entry.at !== 'string') return false;
    const ageMs = Date.now() - new Date(entry.at).getTime();
    return ageMs >= 0 && ageMs < 1000 * 60 * 60 * 24 * 3;
  });
  const exists = data.idempotency.some((entry) => entry.key === key);
  if (exists) return false;
  data.idempotency.unshift({ key, at: now });
  if (MAX_IDEMPOTENCY_KEYS > 0) data.idempotency.splice(MAX_IDEMPOTENCY_KEYS);
  await writeData(data);
  return true;
}

module.exports = { readData, appendAnalytics, appendFeedback, appendIssue, appendSavedUrl, consumeIdempotencyKey };
