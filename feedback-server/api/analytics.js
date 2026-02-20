const { appendAnalytics } = require('../lib/store');
const { requireWriteAuth, checkRateLimit, enforceIdempotency, idempotencyKeyFrom } = require('../lib/security');

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).end();
    return;
  }
  if (!requireWriteAuth(req, res)) return;
  if (!(await checkRateLimit(req, res, 'analytics'))) return;
  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body || {};
    const idemKey = idempotencyKeyFrom(req, body, 'analytics');
    if (!(await enforceIdempotency(res, idemKey))) return;
    const payload = {
      event: typeof body.event === 'string' ? body.event : 'unknown',
      app_version: body.app_version || null,
      os_version: body.os_version || null,
      install_id: body.install_id || null,
      session_id: body.session_id || null,
      saves_count: Number.isFinite(body.saves_count) ? body.saves_count : null,
      urls_saved_total: Number.isFinite(body.urls_saved_total) ? body.urls_saved_total : null,
      raw_bytes_total: Number.isFinite(body.raw_bytes_total) ? body.raw_bytes_total : null,
      stored_bytes_total: Number.isFinite(body.stored_bytes_total) ? body.stored_bytes_total : null,
      query_success: typeof body.query_success === 'boolean' ? body.query_success : null,
      query_latency_ms: Number.isFinite(body.query_latency_ms) ? body.query_latency_ms : null,
      query_latency_p95_ms: Number.isFinite(body.query_latency_p95_ms) ? body.query_latency_p95_ms : null,
      question_length: Number.isFinite(body.question_length) ? body.question_length : null,
      activated: typeof body.activated === 'boolean' ? body.activated : null,
      saved_item_id: typeof body.saved_item_id === 'string' ? body.saved_item_id : null,
      saved_item_title: typeof body.saved_item_title === 'string' ? body.saved_item_title : null,
      timestamp: body.timestamp || null,
    };
    console.log('[analytics]', JSON.stringify(payload));
    await appendAnalytics(payload);
    res.status(200).json({ ok: true });
  } catch (e) {
    console.error('[analytics]', e);
    res.status(500).json({ ok: false, error: 'analytics_write_failed' });
  }
};
