# Save the Knowledge - Feedback Server

Production backend for **Save the Knowledge** desktop app telemetry, feedback, issue reporting, and dashboard analytics.

- Source: https://github.com/Dhanush-adk/save-the-knowledge/tree/main/feedback-server
- Main repository: https://github.com/Dhanush-adk/save-the-knowledge
- Issues: https://github.com/Dhanush-adk/save-the-knowledge/issues

## What this service does

- Ingests app analytics events (`/api/analytics`)
- Stores user feedback (`/api/feedback`)
- Captures runtime/app issues (`/api/issues`)
- Tracks offline-save requests from the browser workflow (`/api/offline-save`)
- Exposes dashboard and KPI APIs (`/api/stats`, `/api/retention-export`)
- Serves app upgrade metadata (`/api/app-version`)
- Supports install-token registration for app clients (`/api/register-install`)

## Architecture

- Runtime: Node.js serverless functions on Vercel
- Storage:
  - Production: MongoDB (`MONGODB_URI`)
  - Fallback: Vercel Blob (`kc/data.json`)
- Optional distributed controls: Upstash Redis REST (rate limiting + idempotency)
- Security model:
  - write auth via API key(s) or install token
  - read auth for dashboard APIs
  - admin password + secure HttpOnly session cookie for dashboard login

## API Endpoints

- `POST /api/register-install`
  - creates a signed install token when `FEEDBACK_TOKEN_SECRET` (or `FEEDBACK_SESSION_SECRET`) is configured
- `POST /api/analytics`
- `POST /api/feedback`
- `POST /api/issues`
- `POST /api/offline-save`
- `GET /api/stats`
- `GET /api/retention-export?format=json|csv`
- `GET /api/app-version`
- `POST /api/admin-login`
- `GET /api/admin-session`
- `POST /api/admin-logout`

## Required Environment Variables

### Core

- `MONGODB_URI` (recommended for production scale)
- `MONGODB_DB` (optional; default: `save_the_knowledge`)
- `BLOB_READ_WRITE_TOKEN` (fallback mode only)
- `FEEDBACK_DATA_ENCRYPTION_KEY` (recommended; encrypts Blob payload)

### Write authentication (choose one strategy)

1. API key strategy
- `FEEDBACK_API_KEY` or `FEEDBACK_API_KEYS`

2. Install token strategy
- `FEEDBACK_TOKEN_SECRET` (preferred) or `FEEDBACK_SESSION_SECRET`
- app calls `POST /api/register-install`, then sends `Authorization: Bearer <token>`

### Dashboard/read protection

- `FEEDBACK_READ_API_KEY` or `FEEDBACK_READ_API_KEYS` (recommended)
- `ALLOW_PUBLIC_DASHBOARD=true` only if intentionally public

### Admin UI session login

- `FEEDBACK_DASHBOARD_PASSWORD` (required for admin-login flow)
- `FEEDBACK_SESSION_SECRET` (required for secure session cookie issuance)

### Optional

- `FEEDBACK_WEBHOOK_URL` (forward feedback payloads)
- `APP_LATEST_VERSION`
- `APP_MINIMUM_VERSION`
- `APP_DOWNLOAD_URL`
- `APP_RELEASE_NOTES`
- `MAX_ANALYTICS`, `MAX_FEEDBACK`, `MAX_SAVED_URLS`, `MAX_ISSUES`, `MAX_IDEMPOTENCY_KEYS`
- `MONGO_READ_LIMIT_ANALYTICS`, `MONGO_READ_LIMIT_FEEDBACK`, `MONGO_READ_LIMIT_SAVED_URLS`, `MONGO_READ_LIMIT_ISSUES`
- `MONGO_KPI_ANALYTICS_LIMIT`

### Optional Redis REST (recommended for production scale)

- `UPSTASH_REDIS_REST_URL` (or `REDIS_REST_URL`)
- `UPSTASH_REDIS_REST_TOKEN` (or `REDIS_REST_TOKEN`)

### Optional rate-limit tuning

- `RATE_LIMIT_ANALYTICS_PER_MIN`
- `RATE_LIMIT_FEEDBACK_PER_MIN`
- `RATE_LIMIT_ISSUES_PER_MIN`
- `RATE_LIMIT_STATS_PER_MIN`
- `RATE_LIMIT_KPIS_PER_MIN`
- `RATE_LIMIT_KPI_EXPORT_PER_MIN`
- `RATE_LIMIT_RETENTION_EXPORT_PER_MIN`
- `RATE_LIMIT_OFFLINE_SAVE_PER_MIN`

## Local Development

```bash
cd feedback-server
npm install
vercel dev
```

Server starts on the local Vercel URL (commonly `http://localhost:3000`).

## Deployment (Vercel)

```bash
cd feedback-server
vercel --prod
```

Production checklist:

1. Configure MongoDB (`MONGODB_URI`) and optional `MONGODB_DB`.
2. Configure write auth (`FEEDBACK_API_KEY(S)` or install-token secrets).
3. Configure read/dashboard auth.
4. If using Blob fallback, set `BLOB_READ_WRITE_TOKEN` and `FEEDBACK_DATA_ENCRYPTION_KEY`.
5. Add Redis REST credentials for distributed rate-limit/idempotency.
6. Set app version metadata for update prompts.

## Minimal Request Examples

### Analytics

```bash
curl -X POST "$BASE_URL/api/analytics" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $FEEDBACK_API_KEY" \
  -H "x-idempotency-key: evt-123" \
  -d '{"event":"session_started","install_id":"mac-001","timestamp":"2026-02-20T12:00:00Z"}'
```

### Feedback

```bash
curl -X POST "$BASE_URL/api/feedback" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $FEEDBACK_API_KEY" \
  -d '{"id":"fb-1","type":"bug","message":"Search hangs on malformed URL"}'
```

### Issue

```bash
curl -X POST "$BASE_URL/api/issues" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $FEEDBACK_API_KEY" \
  -d '{"id":"iss-1","severity":"error","category":"network","message":"upload_failed"}'
```

## Security Notes

- Do not commit secrets (`.env*`, dashboard password, API keys, tokens).
- Keep dashboard APIs private unless intentionally public.
- Use HTTPS in production.
- Use idempotency keys for client retries.

## License

This service is part of the Save the Knowledge project and follows the repository license:
https://github.com/Dhanush-adk/save-the-knowledge/blob/main/LICENSE
