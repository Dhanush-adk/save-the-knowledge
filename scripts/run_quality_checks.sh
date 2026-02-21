#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/3] Running macOS app tests..."
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
xcodebuild \
  -project KnowledgeCache.xcodeproj \
  -scheme KnowledgeCache \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test

echo "[2/3] Running feedback-server syntax checks..."
node --check feedback-server/api/admin-login.js
node --check feedback-server/api/admin-logout.js
node --check feedback-server/api/admin-session.js
node --check feedback-server/api/admin/db-health.js
node --check feedback-server/api/analytics.js
node --check feedback-server/api/app-version.js
node --check feedback-server/api/feedback.js
node --check feedback-server/api/issues.js
node --check feedback-server/api/offline-save.js
node --check feedback-server/api/register-install.js
node --check feedback-server/api/retention-export.js
node --check feedback-server/api/stats.js
node --check feedback-server/lib/kpis.js
node --check feedback-server/lib/security.js
node --check feedback-server/lib/store.js

echo "[3/3] Running KPI aggregator smoke test..."
node -e "const {computeKpis, generatePeriodicSnapshots, generateRetentionCohorts, computeOpsSignals}=require('./feedback-server/lib/kpis'); const rows=[{event:'session_started',install_id:'a',activated:true,timestamp:'2026-02-12T00:00:00Z'},{event:'url_saved',install_id:'a',timestamp:'2026-02-12T00:10:00Z'},{event:'query_answered',install_id:'a',query_success:true,query_latency_ms:210,timestamp:'2026-02-12T00:11:00Z'},{event:'query_answered',install_id:'a',timestamp:'2026-02-13T00:00:00Z'}]; const out=computeKpis(rows); if(!out.summary || out.summary.unique_installs !== 1){process.exit(1);} const snap=generatePeriodicSnapshots(rows,'weekly'); if(!snap.snapshots || snap.snapshots.length < 1){process.exit(1);} const cohorts=generateRetentionCohorts(rows); if(!cohorts.cohorts || cohorts.cohorts.length < 1){process.exit(1);} const ops=computeOpsSignals([{event:'query_answered',query_success:false,query_latency_ms:2200,timestamp:new Date().toISOString()},{event:'feedback_queue_health',pending_queue_size:40,oldest_pending_age_seconds:9000,timestamp:new Date().toISOString()}]); if(!ops.alerts || ops.alerts.length < 1){process.exit(1);} console.log('kpi-smoke-ok');"

echo "All quality checks passed."
