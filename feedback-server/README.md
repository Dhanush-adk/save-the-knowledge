# Knowledge Cache

Knowledge Cache is an offline-first knowledge browser product:
1. Users browse/search content inside the app.
2. Users save pages to offline storage with consent.
3. The app indexes content locally (chunking + embeddings).
4. Users query later and get citation-backed answers from saved documents, even offline.

This repository currently contains the backend service for analytics, feedback, and support-ticket ingestion used by the desktop product.

## Product Vision

Build a privacy-first local knowledge engine where internet is optional for core value:
1. Save web knowledge once.
2. Query and answer from local knowledge any time.
3. Keep user document content local by default.
4. Sync only optional telemetry/support payloads when online.

## MVP Scope

1. In-app single-tab browser (URL/search + save offline).
2. Local ingest pipeline (parse, chunk, embed, index).
3. Offline retrieval + local LLM answers with citations.
4. Local encrypted storage.
5. Optional online telemetry and support ticket sync.
6. Investor-ready dashboard for growth, retention, reliability, and storage-efficiency KPIs.

## Repository Scope (What this repo currently implements)

This repo is the cloud companion service and dashboard:
1. Accept analytics events.
2. Accept feedback reports.
3. Expose stats endpoint for dashboard consumption.
4. Render a simple web dashboard.

## Current API Endpoints

1. `GET /`:
- Dashboard UI.
2. `GET /api/stats`:
- Returns dashboard payload with optional filters via query params:
  - `from=YYYY-MM-DD|ISO`
  - `to=YYYY-MM-DD|ISO`
  - `install_id=<id>`
  - `event=<event_name>`
3. `POST /api/feedback`:
- Stores feedback payload and optionally forwards to webhook.
4. `POST /api/analytics`:
- Stores minimal usage event payload.
5. `POST /api/issues`:
- Stores operational issue/error events raised by app clients when online.
6. `GET /api/app-version`:
- Returns latest app version metadata for in-app upgrade prompts.
7. `POST /api/offline-save`:
- Stores a URL capture request from the browser shell (foundation for offline indexing queue).
8. `GET /api/investor-kpis`:
- Returns aggregated KPI metrics (funnel, retention estimates, latency, storage efficiency, daily trend).
- Includes operational SLO/alert block under `ops` (24h window) for query reliability and queue sync health.
9. `GET /api/investor-export?period=weekly|monthly&format=json|csv`:
- Returns investor snapshot exports for reporting cadence.
10. `GET /api/retention-export?format=json|csv`:
- Returns cohort-level retention exports (D1/D7) for investor reporting and dashboard views.
- Supports optional filters: `from`, `to`, `install_id`, `event`.

## Current Data Store

1. Uses Vercel Blob via `lib/store.js`.
2. Stores rolling recent data in `kc/data.json`.
3. Current limits:
- Analytics: latest 200 entries.
- Feedback: latest 200 entries.
- Issues: latest 200 entries.

## Local Development

1. Install dependencies:
```bash
npm install
```
2. Run with Vercel dev:
```bash
vercel dev
```
3. Open local URL shown by Vercel.

## Production Deployment (Vercel)

1. Install CLI:
```bash
npm i -g vercel
```
2. Deploy:
```bash
vercel --prod
```
3. In Vercel project settings:
- attach a Blob store.
- set `BLOB_READ_WRITE_TOKEN`.
- optionally set `FEEDBACK_WEBHOOK_URL`.
- optionally set `FEEDBACK_API_KEY` to require `x-api-key` on write endpoints.
- optionally set `FEEDBACK_API_KEYS` for rotation support (comma-separated; supports `kid:key` format).
- optionally set Redis REST env vars for distributed controls:
  - `UPSTASH_REDIS_REST_URL` (or `REDIS_REST_URL`)
  - `UPSTASH_REDIS_REST_TOKEN` (or `REDIS_REST_TOKEN`)

## Security and Product Principles

1. Offline-first for user knowledge workflows.
2. Local-first data storage for document content.
3. Minimal telemetry and explicit user consent.
4. Production readiness gates per feature:
- tests required.
- security checks required.
- release quality gates required.
- operational SLO and alert visibility required.

### API hardening (current)
1. Optional API key enforcement on write routes (`POST` endpoints) via `FEEDBACK_API_KEY`.
2. API key rotation-ready validation via `FEEDBACK_API_KEYS` (`kid:key,kid:key` or plain keys).
3. Per-route rate limiting with Redis REST (distributed) when configured; in-memory fallback otherwise.
4. Idempotency support via `x-idempotency-key` header (or payload fallback ids), backed by Redis when configured and blob/local fallback otherwise.

## Documentation Policy

To keep GitHub docs clean:
1. `docs/README.md` is the only docs file intended to be committed.
2. Working planning docs (MVP plan, promotion scripts, implementation playbooks) are local and ignored via `.gitignore`.

## Next Implementation Areas

1. Upgrade backend from Blob JSON to production-grade event/ticket schema.
2. Add auth, rate limits, and abuse controls for API endpoints.
3. Add KPI dictionary-backed investor reporting endpoints.
4. Integrate desktop app telemetry/ticket queue contract.
