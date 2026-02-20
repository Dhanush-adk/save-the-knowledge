const BLOB_PATH = 'kc/data.json';
// 0 means "no cap" (persist everything). Dashboard endpoints should page/slice.
const MAX_ANALYTICS = Number.parseInt(process.env.MAX_ANALYTICS || '0', 10) || 0;
const MAX_FEEDBACK = Number.parseInt(process.env.MAX_FEEDBACK || '0', 10) || 0;
const MAX_SAVED_URLS = Number.parseInt(process.env.MAX_SAVED_URLS || '0', 10) || 0;
const MAX_ISSUES = Number.parseInt(process.env.MAX_ISSUES || '0', 10) || 0;
const MAX_IDEMPOTENCY_KEYS = Number.parseInt(process.env.MAX_IDEMPOTENCY_KEYS || '2000', 10) || 2000;
const MONGO_DB_NAME = (process.env.MONGODB_DB || 'save_the_knowledge').trim();
const MONGO_URI = (process.env.MONGODB_URI || '').trim();
const MONGO_READ_LIMIT_ANALYTICS = Number.parseInt(process.env.MONGO_READ_LIMIT_ANALYTICS || '3000', 10) || 3000;
const MONGO_READ_LIMIT_FEEDBACK = Number.parseInt(process.env.MONGO_READ_LIMIT_FEEDBACK || '1000', 10) || 1000;
const MONGO_READ_LIMIT_SAVED_URLS = Number.parseInt(process.env.MONGO_READ_LIMIT_SAVED_URLS || '3000', 10) || 3000;
const MONGO_READ_LIMIT_ISSUES = Number.parseInt(process.env.MONGO_READ_LIMIT_ISSUES || '1000', 10) || 1000;
const MONGO_KPI_ANALYTICS_LIMIT = Number.parseInt(process.env.MONGO_KPI_ANALYTICS_LIMIT || '50000', 10) || 50000;
const crypto = require('crypto');

let mongoClientPromise = null;
let mongoIndexesReady = false;

function useMongo() {
  return !!MONGO_URI;
}

async function getBlobClient() {
  try {
    const { put, list } = await import('@vercel/blob');
    return { put, list };
  } catch (e) {
    return null;
  }
}

async function getMongoDb() {
  if (!useMongo()) return null;
  if (!mongoClientPromise) {
    mongoClientPromise = (async () => {
      const { MongoClient } = await import('mongodb');
      const client = new MongoClient(MONGO_URI, {
        maxPoolSize: Number.parseInt(process.env.MONGODB_MAX_POOL_SIZE || '20', 10) || 20,
      });
      await client.connect();
      return client;
    })();
  }
  const client = await mongoClientPromise;
  const db = client.db(MONGO_DB_NAME);
  if (!mongoIndexesReady) {
    await ensureMongoIndexes(db);
    mongoIndexesReady = true;
  }
  return db;
}

async function ensureMongoIndexes(db) {
  const analytics = db.collection('analytics');
  const feedback = db.collection('feedback');
  const issues = db.collection('issues');
  const savedUrls = db.collection('saved_urls');
  const idempotency = db.collection('idempotency');

  await Promise.all([
    analytics.createIndex({ at: -1 }),
    analytics.createIndex({ install_id: 1, event: 1, at: -1 }),
    feedback.createIndex({ at: -1 }),
    feedback.createIndex({ install_id: 1, at: -1 }),
    issues.createIndex({ at: -1 }),
    issues.createIndex({ install_id: 1, at: -1 }),
    savedUrls.createIndex({ at: -1 }),
    savedUrls.createIndex({ canonical_url: 1 }, { unique: true }),
    idempotency.createIndex({ key: 1 }, { unique: true }),
    idempotency.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 }),
  ]);
}

function docForInsert(payload) {
  const now = new Date();
  return {
    ...payload,
    _at: now.toISOString(),
    at: now,
  };
}

function sanitizeDoc(doc) {
  if (!doc || typeof doc !== 'object') return null;
  const out = { ...doc };
  delete out._id;
  delete out.at;
  delete out.canonical_url;
  return out;
}

function parseDateInput(raw, endOfDay = false) {
  if (!raw || typeof raw !== 'string') return null;
  const value = raw.trim();
  if (!value) return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const suffix = endOfDay ? 'T23:59:59.999Z' : 'T00:00:00.000Z';
    const d = new Date(`${value}${suffix}`);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

function mongoFilter({ from, to, installId, event } = {}) {
  const filter = {};
  if (from || to) {
    filter.at = {};
    if (from) filter.at.$gte = from;
    if (to) filter.at.$lte = to;
  }
  if (installId) filter.install_id = installId;
  if (event) filter.event = event;
  return filter;
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

async function readDataBlob() {
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

async function writeDataBlob(data) {
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

async function readData() {
  if (useMongo()) {
    try {
      const db = await getMongoDb();
      const [analytics, feedback, saved_urls, issues] = await Promise.all([
        db.collection('analytics').find({}).sort({ at: -1 }).limit(MONGO_READ_LIMIT_ANALYTICS).toArray(),
        db.collection('feedback').find({}).sort({ at: -1 }).limit(MONGO_READ_LIMIT_FEEDBACK).toArray(),
        db.collection('saved_urls').find({}).sort({ at: -1 }).limit(MONGO_READ_LIMIT_SAVED_URLS).toArray(),
        db.collection('issues').find({}).sort({ at: -1 }).limit(MONGO_READ_LIMIT_ISSUES).toArray(),
      ]);
      return {
        analytics: analytics.map(sanitizeDoc).filter(Boolean),
        feedback: feedback.map(sanitizeDoc).filter(Boolean),
        saved_urls: saved_urls.map(sanitizeDoc).filter(Boolean),
        issues: issues.map(sanitizeDoc).filter(Boolean),
        idempotency: [],
      };
    } catch (e) {
      console.error('[store] read mongo fallback to blob', e);
    }
  }
  return readDataBlob();
}

async function appendAnalytics(payload) {
  if (useMongo()) {
    try {
      const db = await getMongoDb();
      await db.collection('analytics').insertOne(docForInsert(payload));
      return;
    } catch (e) {
      console.error('[store] appendAnalytics mongo fallback', e);
    }
  }
  const data = await readDataBlob();
  data.analytics.unshift({ ...payload, _at: new Date().toISOString() });
  if (MAX_ANALYTICS > 0) data.analytics.splice(MAX_ANALYTICS);
  await writeDataBlob(data);
}

async function appendFeedback(payload) {
  if (useMongo()) {
    try {
      const db = await getMongoDb();
      await db.collection('feedback').insertOne(docForInsert(payload));
      return;
    } catch (e) {
      console.error('[store] appendFeedback mongo fallback', e);
    }
  }
  const data = await readDataBlob();
  data.feedback.unshift({ ...payload, _at: new Date().toISOString() });
  if (MAX_FEEDBACK > 0) data.feedback.splice(MAX_FEEDBACK);
  await writeDataBlob(data);
}

async function appendIssue(payload) {
  if (useMongo()) {
    try {
      const db = await getMongoDb();
      await db.collection('issues').insertOne(docForInsert(payload));
      return;
    } catch (e) {
      console.error('[store] appendIssue mongo fallback', e);
    }
  }
  const data = await readDataBlob();
  data.issues.unshift({ ...payload, _at: new Date().toISOString() });
  if (MAX_ISSUES > 0) data.issues.splice(MAX_ISSUES);
  await writeDataBlob(data);
}

async function appendSavedUrl(payload) {
  const next = {
    id: payload.id || `${Date.now()}`,
    url: payload.url,
    title: payload.title || null,
    source: payload.source || 'browser',
    install_id: payload.install_id || null,
    _at: new Date().toISOString(),
  };
  const canonical = canonicalizeUrl(next.url);

  if (useMongo()) {
    try {
      const db = await getMongoDb();
      const now = new Date();
      const key = canonical || next.url;
      const out = await db.collection('saved_urls').findOneAndUpdate(
        { canonical_url: key },
        {
          $set: {
            ...next,
            canonical_url: key,
            at: now,
            _at: now.toISOString(),
          },
          $setOnInsert: {
            id: next.id,
          }
        },
        { upsert: true, returnDocument: 'after' }
      );
      return sanitizeDoc(out?.value || { ...next, canonical_url: key });
    } catch (e) {
      console.error('[store] appendSavedUrl mongo fallback', e);
    }
  }

  const data = await readDataBlob();
  data.saved_urls = data.saved_urls.filter((entry) => {
    const existing = canonicalizeUrl(entry.url || '');
    return !canonical || existing !== canonical;
  });
  data.saved_urls.unshift(next);
  if (MAX_SAVED_URLS > 0) data.saved_urls.splice(MAX_SAVED_URLS);
  await writeDataBlob(data);
  return next;
}

async function consumeIdempotencyKey(key) {
  if (!key) return true;

  if (useMongo()) {
    try {
      const db = await getMongoDb();
      const now = new Date();
      const expires = new Date(now.getTime() + (1000 * 60 * 60 * 24 * 3));
      await db.collection('idempotency').insertOne({ key, at: now, expires_at: expires });
      return true;
    } catch (e) {
      if (e && e.code === 11000) return false;
      console.error('[store] idempotency mongo fallback', e);
    }
  }

  const data = await readDataBlob();
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
  await writeDataBlob(data);
  return true;
}

async function queryStatsData(options = {}) {
  if (!useMongo()) return null;

  const {
    from,
    to,
    installId,
    event,
    limitAnalytics = 200,
    limitFeedback = 200,
    limitSavedUrls = 1000,
    limitIssues = 200,
  } = options;

  const db = await getMongoDb();
  const scoped = mongoFilter({ from, to, installId, event: '' });
  const filtered = mongoFilter({ from, to, installId, event });

  const [analyticsScopeTotal, analyticsTotal, feedbackTotal, savedUrlsTotal, issuesTotal, eventTypes] = await Promise.all([
    db.collection('analytics').countDocuments(scoped),
    db.collection('analytics').countDocuments(filtered),
    db.collection('feedback').countDocuments(mongoFilter({ from, to, installId })),
    db.collection('saved_urls').countDocuments(mongoFilter({ from, to, installId })),
    db.collection('issues').countDocuments(mongoFilter({ from, to, installId })),
    db.collection('analytics').distinct('event', scoped),
  ]);

  const [kpiAnalytics, analytics, feedback, saved_urls, issues] = await Promise.all([
    db.collection('analytics').find(scoped).sort({ at: -1 }).limit(MONGO_KPI_ANALYTICS_LIMIT).toArray(),
    db.collection('analytics').find(filtered).sort({ at: -1 }).limit(Math.max(1, limitAnalytics)).toArray(),
    db.collection('feedback').find(mongoFilter({ from, to, installId })).sort({ at: -1 }).limit(Math.max(1, limitFeedback)).toArray(),
    db.collection('saved_urls').find(mongoFilter({ from, to, installId })).sort({ at: -1 }).limit(Math.max(1, limitSavedUrls)).toArray(),
    db.collection('issues').find(mongoFilter({ from, to, installId })).sort({ at: -1 }).limit(Math.max(1, limitIssues)).toArray(),
  ]);

  return {
    counts: {
      analytics_total: analyticsTotal,
      analytics_scope_total: analyticsScopeTotal,
      feedback_total: feedbackTotal,
      saved_urls_total: savedUrlsTotal,
      issues_total: issuesTotal,
    },
    event_types: (eventTypes || []).map((e) => (e || '').toString().trim()).filter(Boolean).sort((a, b) => a.localeCompare(b)),
    kpi_analytics: kpiAnalytics.map(sanitizeDoc).filter(Boolean),
    analytics: analytics.map(sanitizeDoc).filter(Boolean),
    feedback: feedback.map(sanitizeDoc).filter(Boolean),
    saved_urls: saved_urls.map(sanitizeDoc).filter(Boolean),
    issues: issues.map(sanitizeDoc).filter(Boolean),
  };
}

async function queryAnalyticsForRetention(options = {}) {
  if (!useMongo()) return null;
  const { from, to, installId, event } = options;
  const db = await getMongoDb();
  const filter = mongoFilter({ from, to, installId, event });
  const rows = await db.collection('analytics').find(filter).sort({ at: -1 }).limit(MONGO_KPI_ANALYTICS_LIMIT).toArray();
  return rows.map(sanitizeDoc).filter(Boolean);
}

async function getStorageHealth() {
  const now = new Date().toISOString();
  if (!useMongo()) {
    return {
      mode: 'blob',
      checked_at: now,
      mongo: {
        configured: false,
        connected: false,
        db: null,
        collections: [],
      },
    };
  }

  try {
    const db = await getMongoDb();
    const existing = await db.listCollections({}, { nameOnly: true }).toArray();
    const names = (existing || []).map((c) => c && c.name).filter(Boolean).sort((a, b) => a.localeCompare(b));
    return {
      mode: 'mongo',
      checked_at: now,
      mongo: {
        configured: true,
        connected: true,
        db: MONGO_DB_NAME,
        collections: names,
      },
    };
  } catch (e) {
    return {
      mode: 'blob_fallback',
      checked_at: now,
      mongo: {
        configured: true,
        connected: false,
        db: MONGO_DB_NAME,
        collections: [],
        error: e && e.message ? e.message : 'mongo_unavailable',
      },
    };
  }
}

module.exports = {
  readData,
  appendAnalytics,
  appendFeedback,
  appendIssue,
  appendSavedUrl,
  consumeIdempotencyKey,
  queryStatsData,
  queryAnalyticsForRetention,
  parseDateInput,
  getStorageHealth,
};
