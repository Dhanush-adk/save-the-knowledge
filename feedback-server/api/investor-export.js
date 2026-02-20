const { readData } = require('../lib/store');
const { generateInvestorSnapshots, investorSnapshotsToCsv } = require('../lib/kpis');
const { requireDashboardAccess, checkRateLimit } = require('../lib/security');

module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).end();
    return;
  }
  if (!requireDashboardAccess(req, res)) return;
  if (!(await checkRateLimit(req, res, 'investor_export'))) return;
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const period = (url.searchParams.get('period') || 'weekly').toLowerCase();
    const format = (url.searchParams.get('format') || 'json').toLowerCase();
    const safePeriod = period === 'monthly' ? 'monthly' : 'weekly';
    const safeFormat = format === 'csv' ? 'csv' : 'json';

    const data = await readData();
    const exportData = generateInvestorSnapshots(data.analytics || [], safePeriod);

    // Authenticated dashboard data should never be cached by shared proxies/edges.
    res.setHeader('Cache-Control', 'private, no-store');
    if (safeFormat === 'csv') {
      const csv = investorSnapshotsToCsv(exportData);
      res.setHeader('Content-Type', 'text/csv; charset=utf-8');
      res.setHeader('Content-Disposition', `attachment; filename="investor-${safePeriod}.csv"`);
      res.status(200).send(csv);
      return;
    }

    res.status(200).json(exportData);
  } catch (e) {
    console.error('[investor-export]', e);
    res.status(200).json({
      generated_at: new Date().toISOString(),
      period: 'weekly',
      snapshots: [],
    });
  }
};
