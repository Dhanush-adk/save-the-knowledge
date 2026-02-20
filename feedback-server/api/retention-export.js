const { readData, queryAnalyticsForRetention, parseDateInput } = require('../lib/store');
const { generateRetentionCohorts, retentionCohortsToCsv } = require('../lib/kpis');
const { requireDashboardAccess, checkRateLimit } = require('../lib/security');

function parseTs(entry) {
  const d = new Date(entry?._at || entry?.timestamp || '');
  return Number.isNaN(d.getTime()) ? null : d;
}

function withinRange(ts, from, to) {
  if (!ts) return false;
  if (from && ts < from) return false;
  if (to && ts > to) return false;
  return true;
}

module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).end();
    return;
  }
  if (!requireDashboardAccess(req, res)) return;
  if (!(await checkRateLimit(req, res, 'retention_export'))) return;
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const format = (url.searchParams.get('format') || 'json').toLowerCase();
    const safeFormat = format === 'csv' ? 'csv' : 'json';
    const from = parseDateInput(url.searchParams.get('from'), false);
    const to = parseDateInput(url.searchParams.get('to'), true);
    const installId = (url.searchParams.get('install_id') || '').trim();
    const event = (url.searchParams.get('event') || '').trim();

    let analytics = await queryAnalyticsForRetention({ from, to, installId, event });
    if (!analytics) {
      const data = await readData();
      analytics = (data.analytics || []).filter((entry) => {
        const ts = parseTs(entry);
        if (!withinRange(ts, from, to)) return false;
        if (installId && entry.install_id !== installId) return false;
        if (event && entry.event !== event) return false;
        return true;
      });
    }
    const exportData = generateRetentionCohorts(analytics);

    // Authenticated dashboard data should never be cached by shared proxies/edges.
    res.setHeader('Cache-Control', 'private, no-store');
    if (safeFormat === 'csv') {
      const csv = retentionCohortsToCsv(exportData);
      res.setHeader('Content-Type', 'text/csv; charset=utf-8');
      res.setHeader('Content-Disposition', 'attachment; filename="retention-cohorts.csv"');
      res.status(200).send(csv);
      return;
    }

    res.status(200).json(exportData);
  } catch (e) {
    console.error('[retention-export]', e);
    res.status(200).json({
      generated_at: new Date().toISOString(),
      cohorts: [],
    });
  }
};
