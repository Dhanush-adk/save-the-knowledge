const BLOB_PATH = 'kc/data.json';
const MAX_ANALYTICS = 200;
const MAX_FEEDBACK = 200;
const MAX_SAVED_URLS = 1000;
const MAX_IDEMPOTENCY_KEYS = 2000;

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
    return { analytics: [], feedback: [], saved_urls: [], idempotency: [] };
  }
  try {
    const { list } = client;
    const { blobs } = await list({ prefix: 'kc/' });
    const dataBlob = blobs.find((b) => b.pathname === BLOB_PATH);
    if (!dataBlob?.url) return { analytics: [], feedback: [], saved_urls: [], idempotency: [] };
    const res = await fetch(dataBlob.url);
    if (!res.ok) return { analytics: [], feedback: [], saved_urls: [], idempotency: [] };
    const json = await res.json();
    return {
      analytics: Array.isArray(json.analytics) ? json.analytics : [],
      feedback: Array.isArray(json.feedback) ? json.feedback : [],
      saved_urls: Array.isArray(json.saved_urls) ? json.saved_urls : [],
      idempotency: Array.isArray(json.idempotency) ? json.idempotency : [],
    };
  } catch (e) {
    console.error('[store] read', e);
    return { analytics: [], feedback: [], saved_urls: [], idempotency: [] };
  }
}

async function writeData(data) {
  const client = await getBlobClient();
  if (!client || !process.env.BLOB_READ_WRITE_TOKEN) return;
  try {
    const { put } = client;
    await put(BLOB_PATH, JSON.stringify(data), {
      access: 'public',
      addRandomSuffix: false,
      contentType: 'application/json',
      allowOverwrite: true,
    });
  } catch (e) {
    console.error('[store] write', e);
  }
}

async function appendAnalytics(payload) {
  const data = await readData();
  data.analytics.unshift({ ...payload, _at: new Date().toISOString() });
  data.analytics.splice(MAX_ANALYTICS);
  await writeData(data);
}

async function appendFeedback(payload) {
  const data = await readData();
  data.feedback.unshift({ ...payload, _at: new Date().toISOString() });
  data.feedback.splice(MAX_FEEDBACK);
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
  data.saved_urls.splice(MAX_SAVED_URLS);
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
  data.idempotency.splice(MAX_IDEMPOTENCY_KEYS);
  await writeData(data);
  return true;
}

module.exports = { readData, appendAnalytics, appendFeedback, appendSavedUrl, consumeIdempotencyKey };
