const { requireDashboardAccess, checkRateLimit } = require('../../lib/security');
const { getStorageHealth } = require('../../lib/store');

module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).end();
    return;
  }
  if (!requireDashboardAccess(req, res)) return;
  if (!(await checkRateLimit(req, res, 'stats'))) return;

  try {
    const health = await getStorageHealth();
    res.setHeader('Cache-Control', 'private, no-store');
    res.status(200).json({ ok: true, ...health });
  } catch (e) {
    console.error('[db-health]', e);
    res.status(200).json({
      ok: false,
      mode: 'unknown',
      error: e && e.message ? e.message : 'db_health_failed',
    });
  }
};
