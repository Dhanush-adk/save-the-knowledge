# Knowledge Cache – Feedback & Analytics API (Vercel)

Serverless API + dashboard for the KnowledgeCache app: receive feedback (queued when offline, sent when online) and optional minimal analytics. **Dashboard UI** at the project URL shows all stored analytics and feedback.

## Deploy to Vercel

1. Install Vercel CLI: `npm i -g vercel`
2. From this folder: `cd feedback-server && vercel` (or `vercel --prod` for production)
3. You’ll get a URL like `https://feedback-server-xxx.vercel.app`

## Dashboard (view analytics & feedback)

- Open your deployment URL in a browser: **https://your-project.vercel.app**
- The dashboard shows:
  - **Analytics** – last 200 events (time, event, app version, saves count)
  - **Feedback / bug reports** – last 200 reports (time, type, message, optional email)
- Data is stored in **Vercel Blob**. You must add a Blob store for the dashboard to show data:
  1. Vercel Dashboard → your project → **Storage** → **Create Database** → **Blob** → create a store
  2. Redeploy (`vercel --prod`) so the API can read/write the blob

Without a Blob store, the app still returns 200 for POSTs (feedback/analytics are logged only); the dashboard will show “No analytics yet” / “No feedback yet” until Blob is connected and data is sent.

## Endpoints

- **GET /** – Dashboard UI (this HTML page)
- **GET /api/stats** – JSON: `{ analytics: [...], feedback: [...] }` (for the dashboard)
- **POST /api/feedback** – Bug reports and feedback (stored in Blob + optional webhook)
- **POST /api/analytics** – Minimal usage (event, app_version, saves_count, timestamp; stored in Blob)

## App configuration

In the KnowledgeCache app, set your deployment URL in **`KnowledgeCache/Feedback/FeedbackConfig.swift`** as `FeedbackConfig.baseURL` (no trailing slash).

## Optional: forward feedback elsewhere

Set **FEEDBACK_WEBHOOK_URL** in the Vercel project to a URL that receives the JSON (e.g. Slack incoming webhook or “webhook to email” service).
