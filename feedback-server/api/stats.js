const { readData } = require('../lib/store');
const { computeKpis } = require('../lib/kpis');
const { requireDashboardAccess, checkRateLimit } = require('../lib/security');

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

function parseLimit(raw, fallback) {
  const n = Number.parseInt((raw || '').toString(), 10);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.min(n, 5000);
}

module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).end();
    return;
  }
  if (!requireDashboardAccess(req, res)) return;
  if (!(await checkRateLimit(req, res, 'stats'))) return;
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const from = parseDateInput(url.searchParams.get('from'), false);
    const to = parseDateInput(url.searchParams.get('to'), true);
    const installId = (url.searchParams.get('install_id') || '').trim();
    const event = (url.searchParams.get('event') || '').trim();
    const limitAnalytics = parseLimit(url.searchParams.get('limit_analytics'), 200);
    const limitFeedback = parseLimit(url.searchParams.get('limit_feedback'), 200);
    const limitSavedUrls = parseLimit(url.searchParams.get('limit_saved_urls'), 1000);
    const limitIssues = parseLimit(url.searchParams.get('limit_issues'), 200);

    const data = await readData();
    const analyticsAll = (data.analytics || []).filter((entry) => {
      const ts = parseTs(entry);
      if (!withinRange(ts, from, to)) return false;
      if (installId && entry.install_id !== installId) return false;
      if (event && entry.event !== event) return false;
      return true;
    });
    const feedbackAll = (data.feedback || []).filter((entry) => withinRange(parseTs(entry), from, to));
    const savedUrlsAll = (data.saved_urls || []).filter((entry) => withinRange(parseTs(entry), from, to));
    const issuesAll = (data.issues || []).filter((entry) => withinRange(parseTs(entry), from, to));

    data.counts = {
      analytics_total: analyticsAll.length,
      feedback_total: feedbackAll.length,
      saved_urls_total: savedUrlsAll.length,
      issues_total: issuesAll.length,
    };

    // KPI computation should use the full filtered dataset, even if we only preview N rows in the UI.
    data.kpis = computeKpis(analyticsAll);
    data.analytics = analyticsAll.slice(0, limitAnalytics);
    data.feedback = feedbackAll.slice(0, limitFeedback);
    data.saved_urls = savedUrlsAll.slice(0, limitSavedUrls);
    data.issues = issuesAll.slice(0, limitIssues);
    data.filters = {
      from: from ? from.toISOString() : null,
      to: to ? to.toISOString() : null,
      install_id: installId || null,
      event: event || null,
    };

    // Authenticated dashboard data should never be cached by shared proxies/edges.
    res.setHeader('Cache-Control', 'private, no-store');
    res.status(200).json(data);
  } catch (e) {
    console.error('[stats]', e);
    res.status(200).json({
      analytics: [],
      feedback: [],
      saved_urls: [],
      issues: [],
      kpis: {
        summary: {},
        funnel: {},
        daily_trend: [],
        retention: {},
        ops: { generated_at: new Date().toISOString(), window_hours: 24, slo: {}, alerts: [] },
      },
      filters: { from: null, to: null, install_id: null, event: null },
    });
  }
};
