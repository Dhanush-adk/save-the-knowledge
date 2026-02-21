//
//  FeedbackReporter.swift
//  KnowledgeCache
//
//  Submits feedback (sends when online, queues when offline). Optional minimal analytics when online.
//

import Foundation
import Security

final class FeedbackReporter {
    private let pendingStore: PendingFeedbackStore
    private let pendingIssueStore: PendingIssueStore
    private let pendingAnalyticsStore: PendingAnalyticsStore
    private let baseURL: String
    private let analyticsEnabledKey = "KnowledgeCache.analyticsEnabled"
    private let lastAnalyticsSentKey = "KnowledgeCache.lastAnalyticsSent"
    private let installEventSentKey = "KnowledgeCache.installEventSent"
    private let installIdKey = "KnowledgeCache.installId"
    private let analyticsInterval: TimeInterval = 86400
    private let sessionId = UUID().uuidString
    private let tokenRefreshLeewaySeconds: TimeInterval = 60

    struct AppUpdateInfo: Equatable, Sendable {
        let latestVersion: String
        let minimumVersion: String?
        let downloadURL: String?
        let releaseNotes: String?

        var isUpgradeRequired: Bool {
            guard let minimumVersion else { return false }
            return Self.versionCompare(Self.currentAppVersion, minimumVersion) == .orderedAscending
        }

        var isUpdateAvailable: Bool {
            Self.versionCompare(Self.currentAppVersion, latestVersion) == .orderedAscending
        }

        private static var currentAppVersion: String {
            let info = Bundle.main.infoDictionary ?? [:]
            return (info["CFBundleShortVersionString"] as? String) ?? "0"
        }

        private static func versionCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
            lhs.compare(rhs, options: .numeric)
        }
    }

    init(
        pendingStore: PendingFeedbackStore,
        issueStore: PendingIssueStore = PendingIssueStore(),
        analyticsStore: PendingAnalyticsStore = PendingAnalyticsStore()
    ) {
        self.pendingStore = pendingStore
        self.pendingIssueStore = issueStore
        self.pendingAnalyticsStore = analyticsStore
        self.baseURL = FeedbackConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isAnalyticsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: analyticsEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: analyticsEnabledKey)
        }
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
            let failedCount = max(0, items.count - sentIds.count)
            let successRate = items.isEmpty ? 1.0 : Double(sentIds.count) / Double(items.count)
            let queueMetrics = self.pendingStore.synchronouslyQueueMetrics()
            self.sendAnalyticsEvent(
                event: "feedback_flush",
                metrics: [
                    "pending_queue_size": queueMetrics.count,
                    "oldest_pending_age_seconds": queueMetrics.oldestPendingAgeSeconds,
                    "flush_attempted_count": items.count,
                    "flush_sent_count": sentIds.count,
                    "flush_failed_count": failedCount,
                    "flush_success_rate": successRate,
                    "sync_error_rate": 1.0 - successRate
                ],
                isConnected: isConnected
            )
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
                self.emitQueueHealthEvent(reason: "send_failed_queued", isConnected: isConnected)
            }
            return
        }
        pendingStore.append(item)
        emitQueueHealthEvent(reason: "queued_offline", isConnected: isConnected)
    }

    /// Send minimal analytics (opt-in, throttled to once per interval).
    func sendAnalyticsIfNeeded(savesCount: Int, isConnected: Bool) {
        guard isAnalyticsEnabled, !baseURL.isEmpty else { return }
        let last = UserDefaults.standard.double(forKey: lastAnalyticsSentKey)
        let now = Date().timeIntervalSince1970
        guard now - last >= analyticsInterval else { return }
        var body: [String: Any] = ["saves_count": savesCount]
        body.merge(defaultAnalyticsFields(event: "session")) { _, new in new }
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            if !isConnected {
                self.enqueueAnalyticsBody(body, error: "queued_offline")
                return
            }
            let ok = await self.postJSON(path: FeedbackConfig.analyticsPath, body: body, timeout: 15)
            if ok {
                UserDefaults.standard.set(now, forKey: self.lastAnalyticsSentKey)
            } else {
                self.enqueueAnalyticsBody(body, error: "send_failed")
            }
        }
    }

    /// Send event-level analytics for KPI reporting.
    func sendAnalyticsEvent(event: String, metrics: [String: Any], isConnected: Bool) {
        guard isAnalyticsEnabled, !baseURL.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            var body = self.defaultAnalyticsFields(event: event)
            body.merge(metrics) { _, new in new }
            if !isConnected {
                self.enqueueAnalyticsBody(body, error: "queued_offline")
                return
            }
            let ok = await self.postJSON(path: FeedbackConfig.analyticsPath, body: body, timeout: 15)
            if !ok {
                self.enqueueAnalyticsBody(body, error: "send_failed")
            }
        }
    }

    /// Emit a one-time install event so dashboards can detect first-time installs.
    func sendInstallEventIfNeeded(isConnected: Bool) {
        guard isAnalyticsEnabled, !baseURL.isEmpty else { return }
        if UserDefaults.standard.bool(forKey: installEventSentKey) {
            return
        }
        sendAnalyticsEvent(
            event: "app_installed",
            metrics: [
                "source": "desktop_app",
                "activated": true,
            ],
            isConnected: isConnected
        )
        UserDefaults.standard.set(true, forKey: installEventSentKey)
    }

    func flushPendingAnalytics(isConnected: Bool, completion: ((Int, String?) -> Void)? = nil) {
        guard isConnected, !baseURL.isEmpty, isAnalyticsEnabled else {
            completion?(0, "Not connected or analytics disabled.")
            return
        }
        let items = pendingAnalyticsStore.synchronouslyLoad()
        guard !items.isEmpty else {
            completion?(0, nil)
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            var sentIds: Set<String> = []
            var lastError: String?

            for item in items {
                guard let body = Self.jsonObject(from: item.bodyJSON) else {
                    self.pendingAnalyticsStore.synchronouslyMarkFailure(id: item.id, error: "invalid_payload")
                    lastError = "invalid_payload"
                    continue
                }
                let ok = await self.postJSON(path: FeedbackConfig.analyticsPath, body: body, timeout: 15)
                if ok {
                    sentIds.insert(item.id)
                } else {
                    self.pendingAnalyticsStore.synchronouslyMarkFailure(id: item.id, error: "send_failed")
                    lastError = "send_failed"
                }
            }

            if !sentIds.isEmpty {
                self.pendingAnalyticsStore.synchronouslyRemove(ids: sentIds)
            }

            Task { @MainActor in
                completion?(sentIds.count, sentIds.count == items.count ? nil : lastError)
            }
        }
    }

    func pendingCount() -> Int {
        pendingStore.synchronouslyLoad().count
    }

    /// Emits queue-health metrics while online for operational alerting.
    func emitQueueHealthEvent(reason: String, isConnected: Bool) {
        let queueMetrics = pendingStore.synchronouslyQueueMetrics()
        sendAnalyticsEvent(
            event: "feedback_queue_health",
            metrics: [
                "queue_reason": reason,
                "pending_queue_size": queueMetrics.count,
                "oldest_pending_age_seconds": queueMetrics.oldestPendingAgeSeconds
            ],
            isConnected: isConnected
        )
    }

    func reportIssue(
        category: String,
        severity: String = "error",
        message: String,
        details: String? = nil,
        isConnected: Bool
    ) {
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCategory.isEmpty, !normalizedMessage.isEmpty else { return }

        let item = PendingIssueItem(
            id: UUID().uuidString,
            category: normalizedCategory,
            severity: severity,
            message: normalizedMessage,
            details: details,
            appVersion: Self.appVersion,
            osVersion: Self.osVersion,
            installId: installId,
            sessionId: sessionId,
            timestamp: Self.iso8601(),
            attemptCount: 0,
            lastError: nil
        )

        if isConnected, !baseURL.isEmpty {
            Task.detached(priority: .utility) { [weak self] in
                guard let self = self else { return }
                let (ok, error) = await self.sendIssueItemAsync(item)
                if !ok {
                    self.pendingIssueStore.append(item)
                    if let error {
                        self.pendingIssueStore.synchronouslyMarkFailure(id: item.id, error: error)
                    }
                }
            }
            return
        }

        pendingIssueStore.append(item)
    }

    func flushPendingIssues(isConnected: Bool, completion: ((Int, String?) -> Void)? = nil) {
        guard isConnected, !baseURL.isEmpty else {
            completion?(0, "Not connected or server URL not set.")
            return
        }
        let items = pendingIssueStore.synchronouslyLoad()
        guard !items.isEmpty else {
            completion?(0, nil)
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            var sentIds: Set<String> = []
            var lastError: String?

            for item in items {
                let (ok, error) = await self.sendIssueItemAsync(item)
                if ok {
                    sentIds.insert(item.id)
                } else {
                    let msg = error ?? "send_failed"
                    lastError = msg
                    self.pendingIssueStore.synchronouslyMarkFailure(id: item.id, error: msg)
                }
            }

            if !sentIds.isEmpty {
                self.pendingIssueStore.synchronouslyRemove(ids: sentIds)
            }

            Task { @MainActor in
                completion?(sentIds.count, sentIds.count == items.count ? nil : lastError)
            }
        }
    }

    func checkForAppUpdate() async -> AppUpdateInfo? {
        guard !baseURL.isEmpty, let url = URL(string: baseURL + FeedbackConfig.appVersionPath) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latest = json["latest_version"] as? String,
                  !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return AppUpdateInfo(
                latestVersion: latest,
                minimumVersion: json["minimum_version"] as? String,
                downloadURL: json["download_url"] as? String,
                releaseNotes: json["release_notes"] as? String
            )
        } catch {
            return nil
        }
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
            // Avoid `Optional<...>` values in JSONSerialization (it will fail). Use JSON null explicitly.
            "email": item.email ?? NSNull(),
            "type": item.type,
            "app_version": item.appVersion,
            "os_version": item.osVersion,
            "install_id": installId,
            "session_id": sessionId,
            "timestamp": item.timestamp
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return (false, "Invalid payload") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.addProtectionBypassHeader(to: &request)
        await addWriteAuthHeaders(to: &request)
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

    private func sendIssueItemAsync(_ item: PendingIssueItem) async -> (Bool, String?) {
        guard let url = URL(string: baseURL + FeedbackConfig.issuesPath) else { return (false, "Invalid server URL") }
        let body: [String: Any] = [
            "id": item.id,
            "category": item.category,
            "severity": item.severity,
            "message": item.message,
            "details": item.details ?? NSNull(),
            "app_version": item.appVersion,
            "os_version": item.osVersion,
            "install_id": item.installId,
            "session_id": item.sessionId,
            "timestamp": item.timestamp
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return (false, "Invalid payload") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.addProtectionBypassHeader(to: &request)
        await addWriteAuthHeaders(to: &request)
        request.httpBody = data
        request.timeoutInterval = 20

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 {
                return (false, "Server returned \(code)")
            }
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
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

    private var installId: String {
        if let existing = UserDefaults.standard.string(forKey: installIdKey), !existing.isEmpty {
            return existing
        }
        let next = UUID().uuidString
        UserDefaults.standard.set(next, forKey: installIdKey)
        return next
    }

    private func defaultAnalyticsFields(event: String) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "event": event,
            "app_version": Self.appVersion,
            "os_version": Self.osVersion,
            "install_id": installId,
            "session_id": sessionId,
            "timestamp": Self.iso8601()
        ]
    }

    private func enqueueAnalyticsBody(_ body: [String: Any], error: String?) {
        guard let bodyJSON = Self.jsonString(from: body) else { return }
        var item = PendingAnalyticsItem(
            id: UUID().uuidString,
            bodyJSON: bodyJSON,
            timestamp: Self.iso8601(),
            attemptCount: 0,
            lastError: nil
        )
        if let error {
            item.lastError = error
            item.attemptCount = 1
        }
        pendingAnalyticsStore.append(item)
    }

    private static func jsonString(from object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func jsonObject(from raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func addProtectionBypassHeader(to request: inout URLRequest) {
        let secret = FeedbackConfig.protectionBypassSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            request.setValue(secret, forHTTPHeaderField: "x-vercel-protection-bypass")
        }
    }

    private static func addWriteAPIKeyHeaders(to request: inout URLRequest) {
        let key = FeedbackConfig.writeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        let keyId = FeedbackConfig.writeAPIKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyId.isEmpty {
            request.setValue(keyId, forHTTPHeaderField: "x-api-key-id")
        }
    }

    private func postJSON(path: String, body: [String: Any], timeout: TimeInterval) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: baseURL + path) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.addProtectionBypassHeader(to: &request)
        await addWriteAuthHeaders(to: &request)
        request.httpBody = data
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return code == 200
        } catch {
            return false
        }
    }

    private func addWriteAuthHeaders(to request: inout URLRequest) async {
        if let token = await getOrRegisterInstallToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return
        }
        // Dev fallback only (not for production): allow x-api-key if configured.
        Self.addWriteAPIKeyHeaders(to: &request)
    }

    private func getOrRegisterInstallToken() async -> String? {
        if let existing = InstallTokenKeychain.readToken(), isInstallTokenValid(existing) {
            return existing
        }
        guard let url = URL(string: baseURL + "/api/register-install") else { return nil }
        let body: [String: Any] = ["install_id": installId]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.addProtectionBypassHeader(to: &request)
        request.httpBody = data
        request.timeoutInterval = 15

        do {
            let (respData, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200,
                  let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let token = obj["token"] as? String,
                  isInstallTokenValid(token) else {
                return nil
            }
            _ = InstallTokenKeychain.storeToken(token)
            return token
        } catch {
            return nil
        }
    }

    private func isInstallTokenValid(_ token: String) -> Bool {
        // Format: base64url(payload).hex(hmac)
        let parts = token.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return false }
        guard let payloadData = Self.fromBase64url(String(parts[0])),
              let obj = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
              let exp = obj["exp"] as? Double else { return false }
        let now = Date().timeIntervalSince1970
        return exp > (now + tokenRefreshLeewaySeconds)
    }

    private static func fromBase64url(_ input: String) -> Data? {
        var s = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = s.count % 4
        if pad != 0 { s += String(repeating: "=", count: 4 - pad) }
        return Data(base64Encoded: s)
    }

    private static func iso8601() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

private enum InstallTokenKeychain {
    private static let service = "com.knowledgecache.installtoken"
    private static let account = "install_token_v1"
    private static let cacheLock = NSLock()
    private static var cachedToken: String?

    static func readToken() -> String? {
        cacheLock.lock()
        if let cachedToken, !cachedToken.isEmpty {
            cacheLock.unlock()
            return cachedToken
        }
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        cacheLock.lock()
        cachedToken = token
        cacheLock.unlock()
        return token
    }

    static func storeToken(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let addStatus = SecItemAdd(attrs as CFDictionary, nil)
        if addStatus == errSecSuccess {
            cacheLock.lock()
            cachedToken = token
            cacheLock.unlock()
            return true
        }
        if addStatus == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let updates: [String: Any] = [kSecValueData as String: data]
            let ok = SecItemUpdate(query as CFDictionary, updates as CFDictionary) == errSecSuccess
            if ok {
                cacheLock.lock()
                cachedToken = token
                cacheLock.unlock()
            }
            return ok
        }
        return false
    }
}
