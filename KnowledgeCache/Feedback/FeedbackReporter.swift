//
//  FeedbackReporter.swift
//  KnowledgeCache
//
//  Submits feedback (sends when online, queues when offline). Optional minimal analytics when online.
//

import Foundation

final class FeedbackReporter {
    private let pendingStore: PendingFeedbackStore
    private let baseURL: String
    private let analyticsEnabledKey = "KnowledgeCache.analyticsEnabled"
    private let lastAnalyticsSentKey = "KnowledgeCache.lastAnalyticsSent"
    private let analyticsInterval: TimeInterval = 86400

    init(pendingStore: PendingFeedbackStore) {
        self.pendingStore = pendingStore
        self.baseURL = FeedbackConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isAnalyticsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: analyticsEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: analyticsEnabledKey) }
    }

    /// Call when device is online to send any queued feedback. Runs off main thread.
    /// Completion is called on the main actor with (sentCount, errorMessage). errorMessage is non-nil if any request failed.
    func flushPendingFeedback(isConnected: Bool, completion: ((Int, String?) -> Void)? = nil) {
        guard isConnected, !baseURL.isEmpty else {
            AppLogger.info("Feedback: flush skipped connected=\(isConnected) baseURLEmpty=\(baseURL.isEmpty)")
            completion?(0, "Not connected or server URL not set.")
            return
        }
        let items = pendingStore.synchronouslyLoad()
        guard !items.isEmpty else {
            completion?(0, nil)
            return
        }
        AppLogger.info("Feedback: flushing \(items.count) pending report(s)")
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            var sentIds: Set<String> = []
            var lastError: String?
            for item in items {
                let (ok, error) = await self.sendFeedbackItemAsyncWithError(item)
                if ok { sentIds.insert(item.id) }
                else if let e = error { lastError = e }
            }
            if !sentIds.isEmpty {
                self.pendingStore.synchronouslyRemove(ids: sentIds)
                AppLogger.info("Feedback: sent \(sentIds.count) report(s)")
            }
            let sent = sentIds.count
            Task { @MainActor in
                completion?(sent, sent == items.count ? nil : lastError)
            }
        }
    }

    /// Submit feedback: send now if online, else queue for later.
    func submit(message: String, email: String?, type: String, isConnected: Bool) {
        let item = FeedbackItem(
            id: UUID().uuidString,
            message: message,
            email: email,
            type: type,
            appVersion: Self.appVersion,
            osVersion: Self.osVersion,
            timestamp: Self.iso8601()
        )
        if isConnected, !baseURL.isEmpty {
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                if await self.sendFeedbackItemAsync(item) { return }
                self.pendingStore.append(item)
            }
            return
        }
        pendingStore.append(item)
    }

    /// Send minimal analytics (opt-in, throttled to once per interval).
    func sendAnalyticsIfNeeded(savesCount: Int, isConnected: Bool) {
        guard isAnalyticsEnabled, isConnected, !baseURL.isEmpty else { return }
        let last = UserDefaults.standard.double(forKey: lastAnalyticsSentKey)
        let now = Date().timeIntervalSince1970
        guard now - last >= analyticsInterval else { return }
        let body: [String: Any] = [
            "event": "session",
            "app_version": Self.appVersion,
            "saves_count": savesCount,
            "timestamp": Self.iso8601()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: baseURL + FeedbackConfig.analyticsPath) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.addProtectionBypassHeader(to: &request)
        request.httpBody = data
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                UserDefaults.standard.set(now, forKey: self?.lastAnalyticsSentKey ?? "")
            }
        }.resume()
    }

    func pendingCount() -> Int {
        pendingStore.synchronouslyLoad().count
    }

    private func sendFeedbackItemAsync(_ item: FeedbackItem) async -> Bool {
        let (ok, _) = await sendFeedbackItemAsyncWithError(item)
        return ok
    }

    private func sendFeedbackItemAsyncWithError(_ item: FeedbackItem) async -> (Bool, String?) {
        guard let url = URL(string: baseURL + FeedbackConfig.feedbackPath) else { return (false, "Invalid server URL") }
        let body: [String: Any] = [
            "id": item.id,
            "message": item.message,
            "email": item.email as Any,
            "type": item.type,
            "app_version": item.appVersion,
            "os_version": item.osVersion,
            "timestamp": item.timestamp
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return (false, "Invalid payload") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.addProtectionBypassHeader(to: &request)
        request.httpBody = data
        request.timeoutInterval = 30
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 {
                let msg = "Server returned \(code)"
                AppLogger.warning("Feedback: send failed HTTP \(code) for \(item.id)")
                return (false, msg)
            }
            return (true, nil)
        } catch {
            let msg = error.localizedDescription
            AppLogger.warning("Feedback: send error \(msg) for \(item.id)")
            return (false, msg)
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "—"
        let b = info["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func addProtectionBypassHeader(to request: inout URLRequest) {
        let secret = FeedbackConfig.protectionBypassSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            request.setValue(secret, forHTTPHeaderField: "x-vercel-protection-bypass")
        }
    }

    private static func iso8601() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
