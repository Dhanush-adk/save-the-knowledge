const { readData } = require('../lib/store');
const { generateRetentionCohorts, retentionCohortsToCsv } = require('../lib/kpis');

function parseDateInput(raw, endOfDay = false) {
  if (!raw || typeof raw !== 'string') return null;
  const value = raw.trim();
  if (!value) return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const suffix = endOfDay ? 'T23:59:59.999Z' : 'T00:00:00.000Z';
    const d = new Date(`${value}${suffix}`);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

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
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const format = (url.searchParams.get('format') || 'json').toLowerCase();
    const safeFormat = format === 'csv' ? 'csv' : 'json';
    const from = parseDateInput(url.searchParams.get('from'), false);
    const to = parseDateInput(url.searchParams.get('to'), true);
    const installId = (url.searchParams.get('install_id') || '').trim();
    const event = (url.searchParams.get('event') || '').trim();

    const data = await readData();
    const analytics = (data.analytics || []).filter((entry) => {
      const ts = parseTs(entry);
      if (!withinRange(ts, from, to)) return false;
      if (installId && entry.install_id !== installId) return false;
      if (event && entry.event !== event) return false;
      return true;
    });
    const exportData = generateRetentionCohorts(analytics);

    res.setHeader('Cache-Control', 'public, s-maxage=30, stale-while-revalidate=60');
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
