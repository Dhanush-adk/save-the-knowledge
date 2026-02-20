const { readData } = require('../lib/store');
const { computeInvestorKpis } = require('../lib/kpis');
const { requireDashboardAccess, checkRateLimit } = require('../lib/security');

module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).end();
    return;
  }
  if (!requireDashboardAccess(req, res)) return;
  if (!(await checkRateLimit(req, res, 'investor_kpis'))) return;
  try {
    const data = await readData();
    const kpis = computeInvestorKpis(data.analytics || []);
    // Authenticated dashboard data should never be cached by shared proxies/edges.
    res.setHeader('Cache-Control', 'private, no-store');
    res.status(200).json(kpis);
  } catch (e) {
    console.error('[investor-kpis]', e);
    res.status(200).json({
      generated_at: new Date().toISOString(),
      summary: {},
      funnel: {},
      daily_trend: [],
      retention: {},
      ops: { generated_at: new Date().toISOString(), window_hours: 24, slo: {}, alerts: [] },
    });
  }
};
