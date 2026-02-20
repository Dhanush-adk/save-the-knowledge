const { appendSavedUrl } = require('../lib/store');
const { requireWriteAuth, checkRateLimit, enforceIdempotency, idempotencyKeyFrom } = require('../lib/security');

function parseBody(req) {
  if (!req.body) return {};
  if (typeof req.body === 'string') {
    try {
      return JSON.parse(req.body);
    } catch (e) {
      return {};
    }
  }
  return req.body;
}

function normalizeInput(value) {
  if (typeof value !== 'string') return '';
  return value.trim();
}

function toUrlOrSearch(input) {
  const value = normalizeInput(input);
  if (!value) return null;
  if (/^https?:\/\//i.test(value)) {
    try {
      return new URL(value).toString();
    } catch (e) {
      return null;
    }
  }
  return null;
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).end();
    return;
  }
  if (!requireWriteAuth(req, res)) return;
  if (!(await checkRateLimit(req, res, 'offline-save', 180))) return;

  try {
    const body = parseBody(req);
    const idemKey = idempotencyKeyFrom(req, body, 'offline-save');
    if (!(await enforceIdempotency(res, idemKey))) return;
    const url = toUrlOrSearch(body.url);
    const title = normalizeInput(body.title);
    const source = normalizeInput(body.source) || 'browser';

    if (!url) {
      res.status(400).json({ ok: false, error: 'invalid_url' });
      return;
    }

    const saved = await appendSavedUrl({
      id: body.id,
      url,
      title: title || null,
      source,
    });

    console.log('[offline-save]', JSON.stringify(saved));
    res.status(200).json({ ok: true, saved });
  } catch (e) {
    console.error('[offline-save]', e);
    res.status(500).json({ ok: false, error: 'save_failed' });
  }
};
