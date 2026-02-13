const { readData } = require('../lib/store');
const { computeInvestorKpis } = require('../lib/kpis');

module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).end();
    return;
  }
  try {
    const data = await readData();
    const kpis = computeInvestorKpis(data.analytics || []);
    res.setHeader('Cache-Control', 'public, s-maxage=30, stale-while-revalidate=60');
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
