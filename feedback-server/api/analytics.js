const { appendAnalytics } = require('../lib/store');

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).end();
    return;
  }
  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body || {};
    const { event, app_version, saves_count, timestamp } = body;
    const payload = { event, app_version, saves_count, timestamp };
    console.log('[analytics]', JSON.stringify(payload));
    await appendAnalytics(payload);
    res.status(200).json({ ok: true });
  } catch (e) {
    console.error('[analytics]', e);
    res.status(200).json({ ok: true });
  }
};
