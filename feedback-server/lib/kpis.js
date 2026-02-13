function parseTs(entry) {
  const raw = entry.timestamp || entry._at;
  if (!raw) return null;
  const d = new Date(raw);
  return Number.isNaN(d.getTime()) ? null : d;
}

function dateKey(d) {
  return d.toISOString().slice(0, 10);
}

function percentile(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.max(0, Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p)));
  return sorted[idx];
}

function lastNumeric(events, field) {
  for (const e of events) {
    if (Number.isFinite(e[field])) return e[field];
  }
  return null;
}

function computeRetention(installEvents, dayOffset) {
  let cohort = 0;
  let retained = 0;
  for (const events of installEvents.values()) {
    if (!events.length) continue;
    const days = new Set(events.map((e) => dateKey(e.ts)));
    const first = events[events.length - 1].ts;
    const firstDay = dateKey(first);
    const target = new Date(first);
    target.setUTCDate(target.getUTCDate() + dayOffset);
    const targetDay = dateKey(target);
    cohort += 1;
    if (days.has(targetDay) && targetDay !== firstDay) retained += 1;
  }
  return {
    cohort,
    retained,
    rate: cohort > 0 ? retained / cohort : null,
  };
}

function groupInstallEventsByInstall(analytics) {
  const events = (Array.isArray(analytics) ? analytics : [])
    .map((e) => ({ ...e, ts: parseTs(e) }))
    .filter((e) => e.ts)
    .sort((a, b) => b.ts.getTime() - a.ts.getTime());
  const installEvents = new Map();
  for (const e of events) {
    const installId = typeof e.install_id === 'string' && e.install_id ? e.install_id : null;
    if (!installId) continue;
    if (!installEvents.has(installId)) installEvents.set(installId, []);
    installEvents.get(installId).push(e);
  }
  return installEvents;
}

function computeRetentionForDays(daysSet, first, dayOffset) {
  const firstDay = dateKey(first);
  const target = new Date(first);
  target.setUTCDate(target.getUTCDate() + dayOffset);
  const targetDay = dateKey(target);
  return daysSet.has(targetDay) && targetDay !== firstDay;
}

function computeOpsSignals(analytics) {
  const now = Date.now();
  const windowMs = 24 * 60 * 60 * 1000;
  const windowEvents = (Array.isArray(analytics) ? analytics : [])
    .map((e) => ({ ...e, ts: parseTs(e) }))
    .filter((e) => e.ts && (now - e.ts.getTime()) <= windowMs);

  const queryEvents = windowEvents.filter((e) => e.event === 'query_answered');
  const querySuccessCount = queryEvents.filter((e) => e.query_success === true).length;
  const querySuccessRate = queryEvents.length > 0 ? querySuccessCount / queryEvents.length : null;
  const queryLatencies = queryEvents
    .map((e) => (Number.isFinite(e.query_latency_ms) ? e.query_latency_ms : null))
    .filter((v) => v !== null);
  const queryLatencyP95 = percentile(queryLatencies, 0.95);

  const queueEvents = windowEvents.filter((e) => e.event === 'feedback_queue_health' || e.event === 'feedback_flush');
  const pendingQueueSizes = queueEvents
    .map((e) => (Number.isFinite(e.pending_queue_size) ? e.pending_queue_size : null))
    .filter((v) => v !== null);
  const pendingQueueMax = pendingQueueSizes.length ? Math.max(...pendingQueueSizes) : null;
  const oldestPendingAges = queueEvents
    .map((e) => (Number.isFinite(e.oldest_pending_age_seconds) ? e.oldest_pending_age_seconds : null))
    .filter((v) => v !== null);
  const oldestPendingMax = oldestPendingAges.length ? Math.max(...oldestPendingAges) : null;

  const flushEvents = windowEvents.filter((e) => e.event === 'feedback_flush');
  const attempted = flushEvents.reduce((acc, e) => acc + (Number.isFinite(e.flush_attempted_count) ? e.flush_attempted_count : 0), 0);
  const failed = flushEvents.reduce((acc, e) => acc + (Number.isFinite(e.flush_failed_count) ? e.flush_failed_count : 0), 0);
  const flushSuccessRate = attempted > 0 ? (attempted - failed) / attempted : null;
  const syncErrorRate = attempted > 0 ? failed / attempted : null;

  const alerts = [];
  const check = (condition, alert) => {
    if (condition) alerts.push(alert);
  };

  check(querySuccessRate !== null && querySuccessRate < 0.9, {
    severity: 'high',
    key: 'query_success_rate_24h',
    title: 'Low Query Success Rate',
    value: querySuccessRate,
    threshold: 0.9,
    comparator: '<',
    window: '24h',
  });
  check(queryLatencyP95 !== null && queryLatencyP95 > 1500, {
    severity: 'medium',
    key: 'query_latency_p95_ms_24h',
    title: 'High Query Latency (p95)',
    value: queryLatencyP95,
    threshold: 1500,
    comparator: '>',
    window: '24h',
  });
  check(pendingQueueMax !== null && pendingQueueMax > 25, {
    severity: 'high',
    key: 'pending_queue_size_max_24h',
    title: 'Feedback Queue Backlog High',
    value: pendingQueueMax,
    threshold: 25,
    comparator: '>',
    window: '24h',
  });
  check(oldestPendingMax !== null && oldestPendingMax > 3600, {
    severity: 'high',
    key: 'oldest_pending_age_seconds_max_24h',
    title: 'Oldest Pending Queue Item Too Old',
    value: oldestPendingMax,
    threshold: 3600,
    comparator: '>',
    window: '24h',
  });
  check(syncErrorRate !== null && attempted >= 5 && syncErrorRate > 0.2, {
    severity: 'high',
    key: 'sync_error_rate_24h',
    title: 'High Sync Error Rate',
    value: syncErrorRate,
    threshold: 0.2,
    comparator: '>',
    window: '24h',
  });

  return {
    generated_at: new Date().toISOString(),
    window_hours: 24,
    slo: {
      query_success_rate_24h: querySuccessRate,
      query_latency_p95_ms_24h: queryLatencyP95,
      pending_queue_size_max_24h: pendingQueueMax,
      oldest_pending_age_seconds_max_24h: oldestPendingMax,
      flush_success_rate_24h: flushSuccessRate,
      sync_error_rate_24h: syncErrorRate,
      flush_attempted_count_24h: attempted,
    },
    alerts,
  };
}

function computeInvestorKpis(analytics) {
  const events = (Array.isArray(analytics) ? analytics : [])
    .map((e) => ({ ...e, ts: parseTs(e) }))
    .filter((e) => e.ts)
    .sort((a, b) => b.ts.getTime() - a.ts.getTime());

  const installs = new Set();
  const activatedInstalls = new Set();
  const urlSavedInstalls = new Set();
  const installEvents = new Map();

  let urlSavedEvents = 0;
  let queryTotal = 0;
  let querySuccess = 0;
  const queryLatencies = [];
  const daily = {};

  for (const e of events) {
    const day = dateKey(e.ts);
    daily[day] = daily[day] || { date: day, events: 0, urls_saved: 0, queries: 0, query_success: 0 };
    daily[day].events += 1;

    const installId = typeof e.install_id === 'string' && e.install_id ? e.install_id : null;
    if (installId) {
      installs.add(installId);
      if (!installEvents.has(installId)) installEvents.set(installId, []);
      installEvents.get(installId).push(e);
    }

    if (e.event === 'session_started' && e.activated === true && installId) {
      activatedInstalls.add(installId);
    }

    if (e.event === 'url_saved') {
      urlSavedEvents += 1;
      daily[day].urls_saved += 1;
      if (installId) urlSavedInstalls.add(installId);
    }

    if (e.event === 'query_answered') {
      queryTotal += 1;
      daily[day].queries += 1;
      if (e.query_success === true) {
        querySuccess += 1;
        daily[day].query_success += 1;
      }
      if (Number.isFinite(e.query_latency_ms)) queryLatencies.push(e.query_latency_ms);
    }
  }

  const rawBytes = lastNumeric(events, 'raw_bytes_total');
  const storedBytes = lastNumeric(events, 'stored_bytes_total');
  const storageSavedPct =
    Number.isFinite(rawBytes) && Number.isFinite(storedBytes) && rawBytes > 0
      ? ((rawBytes - storedBytes) / rawBytes) * 100
      : null;

  const d1 = computeRetention(installEvents, 1);
  const d7 = computeRetention(installEvents, 7);

  return {
    generated_at: new Date().toISOString(),
    summary: {
      total_events: events.length,
      unique_installs: installs.size,
      activated_installs: activatedInstalls.size || urlSavedInstalls.size,
      urls_saved_events: urlSavedEvents,
      query_total: queryTotal,
      query_success: querySuccess,
      query_success_rate: queryTotal > 0 ? querySuccess / queryTotal : null,
      query_latency_p50_ms: percentile(queryLatencies, 0.5),
      query_latency_p95_ms: percentile(queryLatencies, 0.95),
      raw_bytes_total: rawBytes,
      stored_bytes_total: storedBytes,
      storage_saved_pct: storageSavedPct,
      d1_retention_rate: d1.rate,
      d7_retention_rate: d7.rate,
    },
    funnel: {
      installs: installs.size,
      activated: activatedInstalls.size || urlSavedInstalls.size,
      urls_saved_events: urlSavedEvents,
      queries: queryTotal,
      successful_queries: querySuccess,
    },
    daily_trend: Object.values(daily).sort((a, b) => a.date.localeCompare(b.date)).slice(-14),
    retention: {
      d1,
      d7,
    },
    ops: computeOpsSignals(events),
  };
}

function periodKey(date, period) {
  if (period === 'monthly') return date.toISOString().slice(0, 7);
  const d = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  const day = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - day);
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  const weekNo = Math.ceil((((d - yearStart) / 86400000) + 1) / 7);
  return `${d.getUTCFullYear()}-W${String(weekNo).padStart(2, '0')}`;
}

function generateInvestorSnapshots(analytics, period = 'weekly') {
  const safePeriod = period === 'monthly' ? 'monthly' : 'weekly';
  const events = (Array.isArray(analytics) ? analytics : [])
    .map((e) => ({ ...e, ts: parseTs(e) }))
    .filter((e) => e.ts);

  const buckets = new Map();
  for (const e of events) {
    const key = periodKey(e.ts, safePeriod);
    if (!buckets.has(key)) buckets.set(key, []);
    buckets.get(key).push(e);
  }

  const periods = [...buckets.keys()].sort();
  const snapshots = periods.map((key) => {
    const k = computeInvestorKpis(buckets.get(key));
    return {
      period: key,
      total_events: k.summary.total_events ?? 0,
      unique_installs: k.summary.unique_installs ?? 0,
      activated_installs: k.summary.activated_installs ?? 0,
      urls_saved_events: k.summary.urls_saved_events ?? 0,
      query_total: k.summary.query_total ?? 0,
      query_success: k.summary.query_success ?? 0,
      query_success_rate: k.summary.query_success_rate,
      query_latency_p95_ms: k.summary.query_latency_p95_ms,
      raw_bytes_total: k.summary.raw_bytes_total,
      stored_bytes_total: k.summary.stored_bytes_total,
      storage_saved_pct: k.summary.storage_saved_pct,
      d1_retention_rate: k.summary.d1_retention_rate,
      d7_retention_rate: k.summary.d7_retention_rate,
    };
  });

  return {
    generated_at: new Date().toISOString(),
    period: safePeriod,
    snapshots,
  };
}

function investorSnapshotsToCsv(exportData) {
  const rows = exportData.snapshots || [];
  const headers = [
    'period',
    'total_events',
    'unique_installs',
    'activated_installs',
    'urls_saved_events',
    'query_total',
    'query_success',
    'query_success_rate',
    'query_latency_p95_ms',
    'raw_bytes_total',
    'stored_bytes_total',
    'storage_saved_pct',
    'd1_retention_rate',
    'd7_retention_rate',
  ];
  const esc = (v) => {
    if (v === null || v === undefined) return '';
    const s = String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines = [headers.join(',')];
  for (const r of rows) {
    lines.push(headers.map((h) => esc(r[h])).join(','));
  }
  return lines.join('\n');
}

function generateRetentionCohorts(analytics) {
  const installEvents = groupInstallEventsByInstall(analytics);
  const cohorts = new Map();

  for (const events of installEvents.values()) {
    if (!events.length) continue;
    const first = events[events.length - 1].ts;
    const cohortDate = dateKey(first);
    const days = new Set(events.map((e) => dateKey(e.ts)));

    if (!cohorts.has(cohortDate)) {
      cohorts.set(cohortDate, {
        cohort_date: cohortDate,
        cohort_size: 0,
        d1_retained: 0,
        d7_retained: 0,
      });
    }
    const row = cohorts.get(cohortDate);
    row.cohort_size += 1;
    if (computeRetentionForDays(days, first, 1)) row.d1_retained += 1;
    if (computeRetentionForDays(days, first, 7)) row.d7_retained += 1;
  }

  const rows = [...cohorts.values()]
    .sort((a, b) => a.cohort_date.localeCompare(b.cohort_date))
    .map((r) => ({
      ...r,
      d1_retention_rate: r.cohort_size > 0 ? r.d1_retained / r.cohort_size : null,
      d7_retention_rate: r.cohort_size > 0 ? r.d7_retained / r.cohort_size : null,
    }));

  return {
    generated_at: new Date().toISOString(),
    cohorts: rows,
  };
}

function retentionCohortsToCsv(exportData) {
  const rows = exportData.cohorts || [];
  const headers = [
    'cohort_date',
    'cohort_size',
    'd1_retained',
    'd1_retention_rate',
    'd7_retained',
    'd7_retention_rate',
  ];
  const esc = (v) => {
    if (v === null || v === undefined) return '';
    const s = String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines = [headers.join(',')];
  for (const r of rows) {
    lines.push(headers.map((h) => esc(r[h])).join(','));
  }
  return lines.join('\n');
}

module.exports = {
  computeInvestorKpis,
  generateInvestorSnapshots,
  investorSnapshotsToCsv,
  generateRetentionCohorts,
  retentionCohortsToCsv,
  computeOpsSignals,
};
