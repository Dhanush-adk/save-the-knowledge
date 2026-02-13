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
        // "https://feedback-server-entlpfvs5-dhanushs-projects-acfd41f9.vercel.app"
        "http://localhost:3000"
    }

    /// Optional: Vercel "Protection Bypass for Automation" secret. If set, sent as
    /// x-vercel-protection-bypass header so the app can POST while deployment protection is on.
    /// Create in Vercel: Settings → Deployment Protection → Protection Bypass for Automation.
    static var protectionBypassSecret: String {
        "" // Set in Vercel if using protection bypass; leave empty when protection is off
    }

    static var feedbackPath: String { "/api/feedback" }
    static var analyticsPath: String { "/api/analytics" }
}
