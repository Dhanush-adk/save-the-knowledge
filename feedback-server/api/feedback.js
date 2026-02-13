const { appendFeedback } = require('../lib/store');
const { requireApiKey, checkRateLimit, enforceIdempotency, idempotencyKeyFrom } = require('../lib/security');

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).end();
    return;
  }
  if (!requireApiKey(req, res)) return;
  if (!(await checkRateLimit(req, res, 'feedback', 120))) return;
  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body || {};
    const idemKey = idempotencyKeyFrom(req, body, 'feedback');
    if (!(await enforceIdempotency(res, idemKey))) return;
    const { id, message, email, type, app_version, os_version, timestamp } = body;
    const payload = { id, message, email, type, app_version, os_version, timestamp };
    console.log('[feedback]', JSON.stringify(payload));
    await appendFeedback(payload);
    const webhookUrl = process.env.FEEDBACK_WEBHOOK_URL;
    if (webhookUrl) {
      await fetch(webhookUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      }).catch((err) => console.error('[feedback] webhook error', err.message));
    }
    res.status(200).json({ ok: true });
  } catch (e) {
    console.error('[feedback]', e);
    res.status(200).json({ ok: true });
  }
};
