const { readData, queryStatsData, parseDateInput } = require('../lib/store');
const { computeKpis } = require('../lib/kpis');
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

    const dbData = await queryStatsData({
      from,
      to,
      installId,
      event,
      limitAnalytics,
      limitFeedback,
      limitSavedUrls,
      limitIssues,
    });

    let response;
    if (dbData) {
      response = {
        analytics: dbData.analytics,
        feedback: dbData.feedback,
        saved_urls: dbData.saved_urls,
        issues: dbData.issues,
        event_types: dbData.event_types,
        counts: dbData.counts,
        kpis: computeKpis(dbData.kpi_analytics),
        filters: {
          from: from ? from.toISOString() : null,
          to: to ? to.toISOString() : null,
          install_id: installId || null,
          event: event || null,
        },
      };
    } else {
      const data = await readData();
      const analyticsScoped = (data.analytics || []).filter((entry) => {
        const ts = parseTs(entry);
        if (!withinRange(ts, from, to)) return false;
        if (installId && entry.install_id !== installId) return false;
        return true;
      });
      const analyticsFiltered = analyticsScoped.filter((entry) => {
        if (event && entry.event !== event) return false;
        return true;
      });
      const feedbackAll = (data.feedback || []).filter((entry) => {
        const ts = parseTs(entry);
        if (!withinRange(ts, from, to)) return false;
        if (installId && entry.install_id !== installId) return false;
        return true;
      });
      const savedUrlsAll = (data.saved_urls || []).filter((entry) => {
        const ts = parseTs(entry);
        if (!withinRange(ts, from, to)) return false;
        if (installId && entry.install_id !== installId) return false;
        return true;
      });
      const issuesAll = (data.issues || []).filter((entry) => {
        const ts = parseTs(entry);
        if (!withinRange(ts, from, to)) return false;
        if (installId && entry.install_id !== installId) return false;
        return true;
      });

      response = {
        analytics: analyticsFiltered.slice(0, limitAnalytics),
        feedback: feedbackAll.slice(0, limitFeedback),
        saved_urls: savedUrlsAll.slice(0, limitSavedUrls),
        issues: issuesAll.slice(0, limitIssues),
        event_types: [...new Set(analyticsScoped.map((entry) => (entry?.event || '').toString().trim()).filter(Boolean))]
          .sort((a, b) => a.localeCompare(b)),
        counts: {
          analytics_total: analyticsFiltered.length,
          analytics_scope_total: analyticsScoped.length,
          feedback_total: feedbackAll.length,
          saved_urls_total: savedUrlsAll.length,
          issues_total: issuesAll.length,
        },
        kpis: computeKpis(analyticsScoped),
        filters: {
          from: from ? from.toISOString() : null,
          to: to ? to.toISOString() : null,
          install_id: installId || null,
          event: event || null,
        },
      };
    }

    // Authenticated dashboard data should never be cached by shared proxies/edges.
    res.setHeader('Cache-Control', 'private, no-store');
    res.status(200).json(response);
  } catch (e) {
    console.error('[stats]', e);
    res.status(200).json({
      analytics: [],
      feedback: [],
      saved_urls: [],
      issues: [],
      event_types: [],
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
