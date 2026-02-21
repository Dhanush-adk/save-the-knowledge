//
//  FeedbackConfig.swift
//  KnowledgeCache
//
//  Set your backend base URL for feedback and analytics. Replace with your hosted endpoint.
//

import Foundation

enum FeedbackConfig {
    /// Base URL of your backend (Vercel deployment). Must end without trailing slash.
    /// Use your PRODUCTION URL from Vercel (Deployments → Production → copy URL). Preview URLs
    /// return 401 due to Deployment Protection. In Vercel: Settings → Deployment Protection
    /// → set to "Only Preview Deployments" so production is public. See feedback-server/FIX-401.md.
    /// Set to empty string to disable sending (feedback will still be queued offline).
    static var baseURL: String {
        // Set this to your current production deployment/custom domain.
        "https://feedback-server-psi.vercel.app"
    }

    /// Optional: Vercel "Protection Bypass for Automation" secret. If set, sent as
    /// x-vercel-protection-bypass header so the app can POST while deployment protection is on.
    /// Create in Vercel: Settings → Deployment Protection → Protection Bypass for Automation.
    static var protectionBypassSecret: String {
        "" // Set in Vercel if using protection bypass; leave empty when protection is off
    }

    /// Optional write API key for `/api/feedback` and `/api/analytics`.
    /// Configure to match `FEEDBACK_API_KEY` (or one entry in `FEEDBACK_API_KEYS`) on the server.
    static var writeAPIKey: String { "" }

    /// Optional key-id when server keys are configured as `kid:key`.
    static var writeAPIKeyId: String {
        ""
    }

    static var feedbackPath: String { "/api/feedback" }
    static var analyticsPath: String { "/api/analytics" }
    static var issuesPath: String { "/api/issues" }
    static var appVersionPath: String { "/api/app-version" }
}
