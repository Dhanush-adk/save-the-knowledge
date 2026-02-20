const { appendIssue } = require('../lib/store');
const { requireWriteAuth, checkRateLimit, enforceIdempotency, idempotencyKeyFrom } = require('../lib/security');

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).end();
    return;
  }
  if (!requireWriteAuth(req, res)) return;
  if (!(await checkRateLimit(req, res, 'feedback'))) return;
  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body || {};
    const idemKey = idempotencyKeyFrom(req, body, 'issues');
    if (!(await enforceIdempotency(res, idemKey))) return;

    const payload = {
      id: typeof body.id === 'string' ? body.id : `${Date.now()}-${Math.random()}`,
      category: typeof body.category === 'string' ? body.category : 'unknown',
      severity: typeof body.severity === 'string' ? body.severity : 'error',
      message: typeof body.message === 'string' ? body.message : '',
      details: typeof body.details === 'string' ? body.details : null,
      app_version: body.app_version || null,
      os_version: body.os_version || null,
      install_id: body.install_id || null,
      session_id: body.session_id || null,
      timestamp: body.timestamp || null,
    };

    if (!payload.message.trim()) {
      res.status(400).json({ ok: false, error: 'message_required' });
      return;
    }

    await appendIssue(payload);
    res.status(200).json({ ok: true });
  } catch (e) {
    console.error('[issues]', e);
    res.status(500).json({ ok: false, error: 'issues_write_failed' });
  }
};
