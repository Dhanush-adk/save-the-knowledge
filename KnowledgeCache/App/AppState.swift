//
//  AppState.swift
//  KnowledgeCache
//
//  Shared DB, store, embedding, pipelines. Created once at launch.
//

import Foundation
import SwiftUI
import AppKit
import CryptoKit

final class FileBookmarkStore {
    private let fileURL: URL
    private var map: [String: String] = [:]

    init(filename: String = "file_bookmarks.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KnowledgeCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent(filename)
        load()
    }

    func saveBookmark(for fileURL: URL) {
        let standardized = fileURL.standardizedFileURL
        do {
            let data = try standardized.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            map[standardized.path] = data.base64EncodedString()
            persist()
        } catch {
            AppLogger.warning("Bookmark: failed for \(standardized.path): \(error.localizedDescription)")
        }
    }

    func resolveURL(for fileURL: URL) -> URL? {
        let standardized = fileURL.standardizedFileURL
        guard let b64 = map[standardized.path], let data = Data(base64Encoded: b64) else {
            return nil
        }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        if stale {
            saveBookmark(for: resolved)
        }
        return resolved
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            map = [:]
            return
        }
        map = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct IngestionQueueJob: Codable, Sendable {
    let id: String
    let canonicalURL: String
    let savedFrom: String
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastError: String?
    var deadLetter: Bool
    let createdAt: Date
    var updatedAt: Date
}

final class IngestionQueueStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.knowledgecache.ingestionqueue", qos: .utility)

    init(appSupportSubpath: String = "KnowledgeCache/ingestion_queue.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fullPath = dir.appendingPathComponent(appSupportSubpath)
        self.fileURL = fullPath
        try? FileManager.default.createDirectory(at: fullPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    @discardableResult
    func enqueueIfNeeded(canonicalURL: String, savedFrom: String, now: Date = Date()) -> Bool {
        queue.sync {
            var list = load()
            let existing = list.contains {
                !$0.deadLetter && $0.canonicalURL == canonicalURL
            }
            guard !existing else { return false }
            list.append(
                IngestionQueueJob(
                    id: UUID().uuidString,
                    canonicalURL: canonicalURL,
                    savedFrom: savedFrom,
                    attemptCount: 0,
                    nextAttemptAt: now,
                    lastError: nil,
                    deadLetter: false,
                    createdAt: now,
                    updatedAt: now
                )
            )
            save(list)
            return true
        }
    }

    func nextReadyJob(now: Date = Date()) -> IngestionQueueJob? {
        queue.sync {
            let list = load()
                .filter { !$0.deadLetter && $0.nextAttemptAt <= now }
                .sorted { lhs, rhs in
                    if lhs.nextAttemptAt == rhs.nextAttemptAt {
                        return lhs.createdAt < rhs.createdAt
                    }
                    return lhs.nextAttemptAt < rhs.nextAttemptAt
                }
            return list.first
        }
    }

    func markSuccess(jobId: String) {
        queue.sync {
            var list = load()
            list.removeAll { $0.id == jobId }
            save(list)
        }
    }

    @discardableResult
    func markRetryOrDeadLetter(
        jobId: String,
        errorMessage: String,
        now: Date = Date(),
        maxAttempts: Int = 6
    ) -> (willRetry: Bool, nextAttemptAt: Date?) {
        queue.sync {
            var list = load()
            guard let idx = list.firstIndex(where: { $0.id == jobId }) else {
                return (false, nil)
            }
            var job = list[idx]
            job.attemptCount += 1
            job.lastError = errorMessage
            job.updatedAt = now
            if job.attemptCount >= maxAttempts {
                job.deadLetter = true
                list[idx] = job
                save(list)
                return (false, nil)
            }
            let delaySeconds = Self.backoffDelaySeconds(attempt: job.attemptCount)
            let next = now.addingTimeInterval(delaySeconds)
            job.nextAttemptAt = next
            list[idx] = job
            save(list)
            return (true, next)
        }
    }

    func secondsUntilNextReady(now: Date = Date()) -> TimeInterval? {
        queue.sync {
            let pending = load()
                .filter { !$0.deadLetter }
                .map(\.nextAttemptAt)
                .min()
            guard let pending else { return nil }
            return max(0, pending.timeIntervalSince(now))
        }
    }

    func queueMetrics(now: Date = Date()) -> (pending: Int, deadLetter: Int, nextInSeconds: Int?) {
        queue.sync {
            let list = load()
            let pending = list.filter { !$0.deadLetter }
            let dead = list.filter(\.deadLetter)
            let next = pending.map(\.nextAttemptAt).min().map { max(0, Int($0.timeIntervalSince(now))) }
            return (pending.count, dead.count, next)
        }
    }

    func listAll() -> [IngestionQueueJob] {
        queue.sync { load() }
    }

    @discardableResult
    func reviveDeadLetters(now: Date = Date()) -> Int {
        queue.sync {
            var list = load()
            var changed = 0
            for idx in list.indices where list[idx].deadLetter {
                list[idx].deadLetter = false
                list[idx].attemptCount = 0
                list[idx].lastError = nil
                list[idx].nextAttemptAt = now
                list[idx].updatedAt = now
                changed += 1
            }
            if changed > 0 {
                save(list)
            }
            return changed
        }
    }

    @discardableResult
    func forceRetryPendingNow(now: Date = Date()) -> Int {
        queue.sync {
            var list = load()
            var changed = 0
            for idx in list.indices where !list[idx].deadLetter && list[idx].nextAttemptAt > now {
                list[idx].nextAttemptAt = now
                list[idx].updatedAt = now
                changed += 1
            }
            if changed > 0 {
                save(list)
            }
            return changed
        }
    }

    private func load() -> [IngestionQueueJob] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([IngestionQueueJob].self, from: data) else {
            return []
        }
        return list
    }

    private func save(_ list: [IngestionQueueJob]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func backoffDelaySeconds(attempt: Int) -> TimeInterval {
        let clamped = max(1, attempt)
        let base = min(3600.0, 15.0 * pow(2.0, Double(clamped - 1)))
        return base
    }
}

enum SaveJobState: Equatable {
    case idle
    case queued(URL)
    case indexing(URL)
    case ready(String)
    case failed(String)
}

enum ChatAnswerMode: String, CaseIterable {
    case grounded
    case ollama

    var title: String {
        switch self {
        case .grounded: return "Knowledge Base"
        case .ollama: return "Ollama"
        }
    }
}

struct CaptureInput: Sendable {
    let url: URL
    let dwellMs: Int
    let scrollPct: Double
    let isManualSave: Bool
}

struct CaptureDecision: Sendable {
    let shouldAutoSave: Bool
    let reason: String
}

protocol CapturePolicyEvaluating {
    func evaluate(_ input: CaptureInput) -> CaptureDecision
}

struct DefaultCapturePolicyEngine: CapturePolicyEvaluating {
    func evaluate(_ input: CaptureInput) -> CaptureDecision {
        if input.isManualSave { return CaptureDecision(shouldAutoSave: true, reason: "manual") }
        if input.dwellMs < 20_000 { return CaptureDecision(shouldAutoSave: false, reason: "low_dwell") }
        if input.scrollPct < 20 { return CaptureDecision(shouldAutoSave: false, reason: "low_scroll") }
        let scheme = input.url.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" { return CaptureDecision(shouldAutoSave: false, reason: "unsupported_scheme") }
        return CaptureDecision(shouldAutoSave: true, reason: "quality_pass")
    }
}

final class SnapshotService {
    private let baseDir: URL

    init(baseURL: URL? = nil, baseDirName: String = "KnowledgeCache/snapshots") {
        let root = baseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = root.appendingPathComponent(baseDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    func saveReaderText(_ text: String, canonicalURL: String) throws -> (path: String, hash: String, sizeBytes: Int) {
        let hash = sha256(text)
        let fileURL = baseDir.appendingPathComponent("reader-\(safeName(canonicalURL))-\(hash.prefix(12)).txt")
        let data = Data(text.utf8)
        try data.write(to: fileURL, options: .atomic)
        return (fileURL.path, hash, data.count)
    }

    func saveBestEffortFullSnapshot(url: URL, fallbackTitle: String, fallbackBody: String) async -> (path: String, hash: String, sizeBytes: Int)? {
        var htmlString: String?
        if let fetched = await fetchHTML(url: url) {
            htmlString = fetched
        } else {
            htmlString = """
            <!doctype html><html><head><meta charset="utf-8"><title>\(fallbackTitle)</title></head><body><pre>\(fallbackBody)</pre></body></html>
            """
        }
        guard let html = htmlString else { return nil }
        let canonical = canonicalizedURLString(url)
        let hash = sha256(html)
        let fileURL = baseDir.appendingPathComponent("full-\(safeName(canonical))-\(hash.prefix(12)).html")
        let data = Data(html.utf8)
        do {
            try data.write(to: fileURL, options: .atomic)
            return (fileURL.path, hash, data.count)
        } catch {
            return nil
        }
    }

    @discardableResult
    func enforceRetention(maxFiles: Int = 2000, maxBytes: Int64 = 2_000_000_000, maxAgeDays: Int = 90, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        struct Record {
            let url: URL
            let createdAt: Date
            let size: Int64
        }

        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400.0)
        var files: [Record] = []
        for fileURL in entries {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let ts = values.contentModificationDate ?? values.creationDate ?? now
            let size = Int64(values.fileSize ?? 0)
            files.append(Record(url: fileURL, createdAt: ts, size: size))
        }

        var removed = 0
        var survivors = files
        for record in files where record.createdAt < cutoff {
            if (try? fm.removeItem(at: record.url)) != nil {
                removed += 1
            }
        }
        survivors.removeAll { $0.createdAt < cutoff }

        survivors.sort { $0.createdAt > $1.createdAt }
        var totalBytes = survivors.reduce(Int64(0)) { $0 + $1.size }
        var idx = survivors.count - 1
        while idx >= 0 && (survivors.count > maxFiles || totalBytes > maxBytes) {
            let target = survivors[idx]
            if (try? fm.removeItem(at: target.url)) != nil {
                removed += 1
                totalBytes -= target.size
                survivors.remove(at: idx)
            }
            idx -= 1
        }
        return removed
    }

    private func fetchHTML(url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
            if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               !contentType.contains("html") {
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func safeName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let out = raw.lowercased().unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(out).prefix(80).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func canonicalizedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        if let host = components.host {
            components.host = host.lowercased()
        }
        return components.url?.absoluteString ?? url.absoluteString
    }
}

@MainActor
final class BrowserSessionService {
    private struct ActiveSession {
        let id: UUID
        let tabId: UUID
        let url: URL
        let startedAt: Date
        var maxScrollPct: Double
    }

    private var sessionsByTab: [UUID: ActiveSession] = [:]
    private var evaluateDecision: @Sendable (CaptureInput) -> CaptureDecision
    private let onVisitCompleted: @Sendable (KnowledgeStore.PageVisit) -> Void
    private var onAutoSaveURL: @Sendable (URL) -> Void

    init(
        evaluateDecision: @escaping @Sendable (CaptureInput) -> CaptureDecision,
        onVisitCompleted: @escaping @Sendable (KnowledgeStore.PageVisit) -> Void,
        onAutoSaveURL: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.evaluateDecision = evaluateDecision
        self.onVisitCompleted = onVisitCompleted
        self.onAutoSaveURL = onAutoSaveURL
    }

    func updateEvaluator(_ evaluator: @escaping @Sendable (CaptureInput) -> CaptureDecision) {
        evaluateDecision = evaluator
    }

    func updateAutoSaveHandler(_ handler: @escaping @Sendable (URL) -> Void) {
        onAutoSaveURL = handler
    }

    func navigationStarted(tabId: UUID, url: URL) {
        finalize(tabId: tabId, endedAt: Date())
        sessionsByTab[tabId] = ActiveSession(
            id: UUID(),
            tabId: tabId,
            url: url,
            startedAt: Date(),
            maxScrollPct: 0
        )
    }

    func navigationFinished(tabId: UUID, url: URL) {
        guard var session = sessionsByTab[tabId] else { return }
        session.maxScrollPct = max(session.maxScrollPct, 5)
        sessionsByTab[tabId] = session
    }

    func updateScroll(tabId: UUID, scrollPct: Double) {
        guard var session = sessionsByTab[tabId] else { return }
        session.maxScrollPct = max(session.maxScrollPct, scrollPct)
        sessionsByTab[tabId] = session
    }

    func close(tabId: UUID) {
        finalize(tabId: tabId, endedAt: Date())
    }

    private func finalize(tabId: UUID, endedAt: Date) {
        guard let session = sessionsByTab.removeValue(forKey: tabId) else { return }
        let dwellMs = max(0, Int(endedAt.timeIntervalSince(session.startedAt) * 1000))
        let visit = KnowledgeStore.PageVisit(
            id: session.id,
            url: session.url.absoluteString,
            tabId: session.tabId,
            startedAt: session.startedAt,
            endedAt: endedAt,
            dwellMs: dwellMs,
            scrollPct: session.maxScrollPct
        )
        onVisitCompleted(visit)
        let decision = evaluateDecision(
            CaptureInput(url: session.url, dwellMs: dwellMs, scrollPct: session.maxScrollPct, isManualSave: false)
        )
        if decision.shouldAutoSave {
            onAutoSaveURL(session.url)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    private static let useOllamaAnswersKey = "KnowledgeCache.useOllamaAnswers"
    private static let chatAnswerModeKey = "KnowledgeCache.chatAnswerMode"
    private static let legacyUseAgenticFolderSearchKey = "KnowledgeCache.useAgenticFolderSearch"
    private static let legacyAgenticSearchFolderPathKey = "KnowledgeCache.agenticSearchFolderPath"
    nonisolated private static let autoSaveVisitedPagesKey = "KnowledgeCache.autoSaveVisitedPages"
    nonisolated private static let autoSaveDwellSecondsKey = "KnowledgeCache.autoSaveDwellSeconds"
    nonisolated private static let autoSaveScrollPercentKey = "KnowledgeCache.autoSaveScrollPercent"
    nonisolated private static let autoSaveAllowDomainsKey = "KnowledgeCache.autoSaveAllowDomains"
    nonisolated private static let autoSaveDenyDomainsKey = "KnowledgeCache.autoSaveDenyDomains"

    let db: Database
    let store: KnowledgeStore
    let embedding: EmbeddingService
    let pipeline: IngestionPipeline
    let search: SemanticSearch
    let reindexController: ReindexController
    let networkMonitor: NetworkMonitor
    let feedbackReporter: FeedbackReporter
    let ollamaManager: OllamaServiceManager
    let fileBookmarkStore: FileBookmarkStore
    let ingestionQueueStore: IngestionQueueStore
    let capturePolicy: any CapturePolicyEvaluating
    let snapshotService: SnapshotService
    let browserSessionService: BrowserSessionService

    @Published var savedItems: [KnowledgeItem] = []
    @Published var reindexInProgress = false
    @Published var reindexError: String?
    @Published var reindexProgressCurrent: Int = 0
    @Published var reindexProgressTotal: Int = 0
    @Published var reindexStatusMessage: String?
    @Published var historyItems: [QueryHistoryItem] = []
    @Published var chatThreads: [ChatThread] = []
    @Published var archivedChatThreads: [ChatThread] = []
    @Published var activeChatMessages: [ChatMessage] = []
    @Published var selectedChatThreadId: UUID?
    @Published var chatAnalytics: KnowledgeStore.ChatAnalyticsSummary?
    @Published var topChatThreadStats: [KnowledgeStore.ChatThreadStat] = []
    @Published var isSaveInProgress = false
    @Published var saveError: String?
    @Published var searchInProgress = false
    @Published var lastAnswer: AnswerWithSources?
    @Published var searchError: String?
    @Published var chatInProgress = false
    @Published var chatError: String?
    @Published var chatAnswerMode: ChatAnswerMode {
        didSet {
            UserDefaults.standard.set(chatAnswerMode.rawValue, forKey: Self.chatAnswerModeKey)
            useOllamaAnswers = (chatAnswerMode == .ollama)
        }
    }
    @Published var ollamaAvailability: OllamaClient.Availability = .init(
        isServerReachable: false,
        isModelAvailable: false,
        model: OllamaClient.defaultModel
    )
    @Published var availableAppUpdate: FeedbackReporter.AppUpdateInfo?
    @Published var saveSuccess: String?
    @Published var saveJobState: SaveJobState = .idle
    @Published var queryLatencyP95Ms: Int = 0
    @Published var useOllamaAnswers: Bool {
        didSet {
            UserDefaults.standard.set(useOllamaAnswers, forKey: Self.useOllamaAnswersKey)
        }
    }
    @Published var autoSaveVisitedPages: Bool {
        didSet { UserDefaults.standard.set(autoSaveVisitedPages, forKey: Self.autoSaveVisitedPagesKey) }
    }
    @Published var autoSaveDwellSeconds: Double {
        didSet { UserDefaults.standard.set(autoSaveDwellSeconds, forKey: Self.autoSaveDwellSecondsKey) }
    }
    @Published var autoSaveScrollPercent: Double {
        didSet { UserDefaults.standard.set(autoSaveScrollPercent, forKey: Self.autoSaveScrollPercentKey) }
    }
    @Published var autoSaveAllowDomains: String {
        didSet { UserDefaults.standard.set(autoSaveAllowDomains, forKey: Self.autoSaveAllowDomainsKey) }
    }
    @Published var autoSaveDenyDomains: String {
        didSet { UserDefaults.standard.set(autoSaveDenyDomains, forKey: Self.autoSaveDenyDomainsKey) }
    }
    @Published var ingestionQueuePendingCount: Int = 0
    @Published var ingestionQueueDeadLetterCount: Int = 0
    @Published var ingestionQueueNextRetrySeconds: Int?

    private var recentQueryLatenciesMs: [Int] = []
    private var autoSavedCanonicalURLs: Set<String> = []
    private var queueWorkerTask: Task<Void, Never>?

    init() {
        UserDefaults.standard.removeObject(forKey: Self.legacyUseAgenticFolderSearchKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyAgenticSearchFolderPathKey)
        let initialUseOllamaAnswers = UserDefaults.standard.object(forKey: Self.useOllamaAnswersKey) as? Bool ?? false
        self.useOllamaAnswers = initialUseOllamaAnswers
        let persistedMode = UserDefaults.standard.string(forKey: Self.chatAnswerModeKey)
            .flatMap { ChatAnswerMode(rawValue: $0) }
        self.chatAnswerMode = persistedMode ?? (initialUseOllamaAnswers ? .ollama : .grounded)
        self.autoSaveVisitedPages = UserDefaults.standard.object(forKey: Self.autoSaveVisitedPagesKey) as? Bool ?? true
        self.autoSaveDwellSeconds = UserDefaults.standard.object(forKey: Self.autoSaveDwellSecondsKey) as? Double ?? 20.0
        self.autoSaveScrollPercent = UserDefaults.standard.object(forKey: Self.autoSaveScrollPercentKey) as? Double ?? 20.0
        self.autoSaveAllowDomains = UserDefaults.standard.string(forKey: Self.autoSaveAllowDomainsKey) ?? ""
        self.autoSaveDenyDomains = UserDefaults.standard.string(forKey: Self.autoSaveDenyDomainsKey) ?? ""
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("KnowledgeCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let path = appDir.appendingPathComponent("knowledge.db").path
        let database = Database(path: path)
        try? database.open()
        self.db = database
        self.store = KnowledgeStore(db: database)
        self.embedding = EmbeddingService()
        let structuredScriptURL = Bundle.main.url(forResource: "extract_structured", withExtension: "py")
        self.pipeline = IngestionPipeline(store: store, embedding: embedding, structuredExtractionScriptURL: structuredScriptURL)
        self.search = SemanticSearch(store: store, embedding: embedding)
        self.reindexController = ReindexController(store: store, embedding: embedding)
        self.networkMonitor = NetworkMonitor()
        let pendingStore = PendingFeedbackStore()
        let issueStore = PendingIssueStore()
        self.feedbackReporter = FeedbackReporter(pendingStore: pendingStore, issueStore: issueStore)
        self.ollamaManager = OllamaServiceManager()
        self.fileBookmarkStore = FileBookmarkStore()
        self.ingestionQueueStore = IngestionQueueStore()
        self.capturePolicy = DefaultCapturePolicyEngine()
        self.snapshotService = SnapshotService()
        self.browserSessionService = BrowserSessionService(
            evaluateDecision: { _ in
                CaptureDecision(shouldAutoSave: false, reason: "config_pending")
            },
            onVisitCompleted: { [weak store] visit in
                try? store?.insertPageVisit(visit)
            },
            onAutoSaveURL: { _ in }
        )
        self.browserSessionService.updateEvaluator { [weak self] input in
            guard self != nil else {
                return CaptureDecision(shouldAutoSave: false, reason: "app_unavailable")
            }
            return Self.evaluateCaptureDecisionFromDefaults(input)
        }
        self.browserSessionService.updateAutoSaveHandler { [weak self] url in
            Task { @MainActor in
                self?.autoSaveVisitedURLIfNeeded(url)
            }
        }
        networkMonitor.onBecameConnected = { [weak self] in
            Task { @MainActor in
                let connected = self?.networkMonitor.isConnected ?? false
                self?.feedbackReporter.emitQueueHealthEvent(reason: "network_became_online", isConnected: connected)
                self?.feedbackReporter.flushPendingFeedback(isConnected: connected)
                self?.feedbackReporter.flushPendingIssues(isConnected: connected)
                self?.feedbackReporter.flushPendingAnalytics(isConnected: connected)
                await self?.refreshAppUpdateInfo()
                await self?.refreshOllamaAvailability()
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let connected = networkMonitor.isConnected
            AppLogger.info("Feedback: initial flush check connected=\(connected)")
            feedbackReporter.emitQueueHealthEvent(reason: "app_launch", isConnected: connected)
            feedbackReporter.flushPendingFeedback(isConnected: connected)
            feedbackReporter.flushPendingIssues(isConnected: connected)
            feedbackReporter.flushPendingAnalytics(isConnected: connected)
            feedbackReporter.sendInstallEventIfNeeded(isConnected: connected)
            feedbackReporter.sendAnalyticsIfNeeded(savesCount: (try? store.fetchAllItems())?.count ?? 0, isConnected: connected)
            trackSessionStarted()
            await refreshAppUpdateInfo()
            await refreshOllamaAvailability()
        }
        Task.detached(priority: .utility) { [weak embedding] in
            _ = embedding?.embedOne("warmup")
        }
        refreshChatThreads()
        refreshChatAnalytics()
        refreshIngestionQueueMetrics()
        triggerQueueWorker()
        AppLogger.info("App started; embedding warmup scheduled")
    }

    func optimizeStorage() {
        try? store.optimizeStorage()
    }

    func reindexAll() {
        reindexError = nil
        reindexStatusMessage = nil
        reindexInProgress = true
        reindexProgressCurrent = 0
        reindexProgressTotal = 0
        let controller = reindexController
        Task.detached(priority: .userInitiated) {
            do {
                try controller.reindexAll { current, total in
                    Task { @MainActor in
                        self.reindexProgressCurrent = current
                        self.reindexProgressTotal = total
                    }
                }
                await MainActor.run {
                    self.refreshItems()
                    self.reindexInProgress = false
                    self.reindexStatusMessage = self.reindexProgressTotal > 0
                        ? "Reindex complete: \(self.reindexProgressCurrent)/\(self.reindexProgressTotal) chunks updated."
                        : "Reindex complete."
                }
            } catch {
                await MainActor.run {
                    self.reindexError = error.localizedDescription
                    self.reindexInProgress = false
                    self.reindexStatusMessage = nil
                }
            }
        }
    }

    func refreshItems() {
        savedItems = (try? store.fetchAllItems()) ?? []
    }

    func refreshHistory() {
        historyItems = (try? store.fetchHistory()) ?? []
    }

    func refreshChatThreads(selectLatestIfNeeded: Bool = true) {
        chatThreads = (try? store.fetchChatThreads()) ?? []
        archivedChatThreads = (try? store.fetchArchivedChatThreads()) ?? []
        if let selected = selectedChatThreadId,
           chatThreads.contains(where: { $0.id == selected }) {
            loadChatThread(id: selected)
            return
        }
        guard selectLatestIfNeeded else {
            selectedChatThreadId = nil
            activeChatMessages = []
            return
        }
        if let first = chatThreads.first {
            loadChatThread(id: first.id)
        } else {
            selectedChatThreadId = nil
            activeChatMessages = []
        }
        refreshChatAnalytics()
    }

    func createNewChat() {
        let now = Date()
        let thread = ChatThread(
            title: "New chat",
            createdAt: now,
            updatedAt: now,
            lastMessagePreview: ""
        )
        try? store.insertChatThread(thread)
        refreshChatThreads(selectLatestIfNeeded: false)
        selectedChatThreadId = thread.id
        activeChatMessages = []
        chatError = nil
        refreshChatAnalytics()
    }

    func loadChatThread(id: UUID) {
        selectedChatThreadId = id
        activeChatMessages = (try? store.fetchChatMessages(threadId: id)) ?? []
        chatError = nil
    }

    func deleteSelectedChat() {
        guard let selectedChatThreadId else { return }
        try? store.archiveChatThread(threadId: selectedChatThreadId)
        refreshChatThreads(selectLatestIfNeeded: true)
    }

    func restoreArchivedChat(threadId: UUID) {
        try? store.unarchiveChatThread(threadId: threadId)
        refreshChatThreads(selectLatestIfNeeded: false)
        loadChatThread(id: threadId)
    }

    func renameSelectedChat(to rawTitle: String) {
        guard let threadId = selectedChatThreadId else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        try? store.updateChatThread(threadId: threadId, title: title, updatedAt: Date())
        refreshChatThreads(selectLatestIfNeeded: false)
        loadChatThread(id: threadId)
    }

    func permanentlyDeleteSelectedChat() {
        guard let selectedChatThreadId else { return }
        try? store.deleteChatThread(threadId: selectedChatThreadId)
        refreshChatThreads(selectLatestIfNeeded: true)
    }

    func sendChatMessage(_ rawText: String) {
        let question = Self.normalizeChatQuery(rawText)
        guard !question.isEmpty else { return }
        guard !chatInProgress else { return }

        chatError = nil
        chatInProgress = true

        let threadId: UUID
        if let selected = selectedChatThreadId {
            threadId = selected
        } else {
            let now = Date()
            let title = Self.chatThreadTitle(from: question)
            let thread = ChatThread(
                title: title,
                createdAt: now,
                updatedAt: now,
                lastMessagePreview: question
            )
            try? store.insertChatThread(thread)
            threadId = thread.id
            selectedChatThreadId = thread.id
        }

        let now = Date()
        let userMessage = ChatMessage(
            threadId: threadId,
            role: .user,
            content: question,
            createdAt: now
        )
        try? store.insertChatMessage(userMessage)
        activeChatMessages.append(userMessage)
        if let idx = chatThreads.firstIndex(where: { $0.id == threadId }) {
            if chatThreads[idx].title == "New chat" && activeChatMessages.filter({ $0.role == .user }).count <= 1 {
                let newTitle = Self.chatThreadTitle(from: question)
                chatThreads[idx].title = newTitle
                try? store.updateChatThread(threadId: threadId, title: newTitle, updatedAt: now, lastMessagePreview: String(question.prefix(140)))
            }
            chatThreads[idx].updatedAt = now
            chatThreads[idx].lastMessagePreview = String(question.prefix(140))
        } else {
            chatThreads.insert(
                ChatThread(
                    id: threadId,
                    title: Self.chatThreadTitle(from: question),
                    createdAt: now,
                    updatedAt: now,
                    lastMessagePreview: String(question.prefix(140))
                ),
                at: 0
            )
        }
        chatThreads.sort { $0.updatedAt > $1.updatedAt }

        let requestedMode = chatAnswerMode
        let ollamaReady = ollamaAvailability.isServerReachable && ollamaAvailability.isModelAvailable
        let canUseOllama = ollamaReady
        let useOllama = requestedMode == .ollama && ollamaReady
        if requestedMode == .ollama && !ollamaReady {
            chatError = "Ollama is not ready. Falling back to Knowledge Base mode for this response."
        }
        let search = self.search
        let store = self.store
        let priorMessages = activeChatMessages
        let startedAt = Date()

        Task.detached(priority: .userInitiated) {
            let assistantMessage: ChatMessage
            let shouldUseKnowledgeBase = Self.shouldPreferKnowledgeBase(
                question: question,
                requestedMode: requestedMode,
                canUseOllama: canUseOllama
            )

            if !shouldUseKnowledgeBase {
                if canUseOllama {
                    assistantMessage = await Self.generateGeneralAssistantMessage(
                        threadId: threadId,
                        question: question,
                        streamWithUI: { messageId, onToken in
                            await MainActor.run {
                                self.activeChatMessages.append(
                                    ChatMessage(
                                        id: messageId,
                                        threadId: threadId,
                                        role: .assistant,
                                        content: "",
                                        sources: [],
                                        suggestions: [],
                                        createdAt: Date()
                                    )
                                )
                            }
                            let stream = await OllamaClient.streamGenerate(
                                prompt: question,
                                system: Self.generalOllamaSystemPrompt(),
                                model: OllamaClient.defaultModel
                            ) { token in
                                await MainActor.run {
                                    self.updateStreamingAssistantContent(threadId: threadId, messageId: messageId, append: token)
                                }
                                await onToken()
                            }
                            return stream.text
                        },
                        typewriterFallback: { messageId, text, suggestions in
                            await self.typewriterFallback(
                                threadId: threadId,
                                messageId: messageId,
                                finalText: text,
                                sources: [],
                                suggestions: suggestions
                            )
                        }
                    )
                } else {
                    let text = Self.generalFallbackReply(for: question)
                    let answer = AnswerWithSources(answerText: text, sources: [])
                    assistantMessage = ChatMessage(
                        threadId: threadId,
                        role: .assistant,
                        content: answer.answerText,
                        sources: answer.sources,
                        suggestions: Self.generalConversationSuggestions(),
                        createdAt: Date()
                    )
                }

                let historyItem = QueryHistoryItem(
                    question: question,
                    answerText: assistantMessage.content,
                    sources: assistantMessage.sources
                )
                try? store.insertHistory(item: historyItem)
                let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                await MainActor.run {
                    self.trackQuery(
                        question: question,
                        success: !assistantMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        latencyMs: latencyMs
                    )
                }
            } else {
                let parallelOllamaTask: Task<String?, Never>? = (canUseOllama && !useOllama)
                    ? Task(priority: .userInitiated) {
                        await OllamaClient.generate(
                            prompt: question,
                            system: Self.generalOllamaSystemPrompt(),
                            model: OllamaClient.defaultModel
                        )
                    }
                    : nil
                let retrievalQuery = Self.contextualRetrievalQuery(currentQuestion: question, priorMessages: priorMessages)
                let outcome = search.search(query: retrievalQuery, topK: 12)
                switch outcome {
                case .reindexRequired:
                    let text: String
                    if canUseOllama {
                        let parallelText = await Self.awaitTrimmedOllamaText(parallelOllamaTask)
                        if let parallelText {
                            text = parallelText
                        } else {
                            text = "Unfortunately, indexing is required and Ollama could not answer right now. Run Reindex all now, then retry."
                        }
                    } else {
                        text = "Embedding index needs reindexing before chat can answer. Go to Settings and run Reindex all now."
                    }

                    let answer = AnswerWithSources(answerText: text, sources: [])
                    assistantMessage = ChatMessage(
                        threadId: threadId,
                        role: .assistant,
                        content: answer.answerText,
                        sources: answer.sources,
                        suggestions: Self.followUpSuggestions(question: question, answer: answer),
                        createdAt: Date()
                    )

                    let historyItem = QueryHistoryItem(
                        question: question,
                        answerText: answer.answerText,
                        sources: answer.sources
                    )
                    try? store.insertHistory(item: historyItem)
                    let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    await MainActor.run {
                        self.trackQuery(
                            question: question,
                            success: !answer.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            latencyMs: latencyMs
                        )
                    }
                case .results(let results):
                    let bestScore = results.first?.score ?? 0
                    let retrievalAnswer = AnswerGenerator.generate(results: results, query: question)
                    let weakRetrieval = Self.shouldTryOllamaAfterRetrieval(answer: retrievalAnswer, bestScore: bestScore)
                    var answer = retrievalAnswer
                    let shouldAttemptOllama = canUseOllama && (weakRetrieval || useOllama)

                    if shouldAttemptOllama && useOllama {
                        let answerId = UUID()
                        await MainActor.run {
                            self.activeChatMessages.append(
                                ChatMessage(
                                    id: answerId,
                                    threadId: threadId,
                                    role: .assistant,
                                    content: "",
                                    sources: [],
                                    suggestions: [],
                                    createdAt: Date()
                                )
                            )
                        }

                        let prompt = AnswerGenerator.composePrompt(results: results, query: question)
                        let stream = await OllamaClient.streamGenerate(
                            prompt: prompt.userPrompt,
                            system: prompt.systemPrompt,
                            model: OllamaClient.defaultModel
                        ) { token in
                            await MainActor.run {
                                self.updateStreamingAssistantContent(threadId: threadId, messageId: answerId, append: token)
                            }
                        }

                        if let streamedText = stream.text, !streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let trimmed = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
                            let streamedAnswer = AnswerWithSources(answerText: trimmed, sources: retrievalAnswer.sources)
                            answer = streamedAnswer
                            await MainActor.run {
                                self.updateStreamingAssistantContent(
                                    threadId: threadId,
                                    messageId: answerId,
                                    overwrite: trimmed,
                                    sources: retrievalAnswer.sources,
                                    suggestions: Self.followUpSuggestions(question: question, answer: streamedAnswer)
                                )
                            }
                        } else {
                            if let err = stream.error, !err.isEmpty {
                                await MainActor.run {
                                    self.feedbackReporter.reportIssue(
                                        category: "ollama_stream_failed",
                                        severity: "warning",
                                        message: "Ollama streaming failed; deterministic fallback used.",
                                        details: err,
                                        isConnected: self.networkMonitor.isConnected
                                    )
                                }
                            }
                            if weakRetrieval {
                                answer = AnswerWithSources(
                                    answerText: "Unfortunately, I couldn't find a confident answer from your saved sources, and Ollama could not answer right now.",
                                    sources: []
                                )
                            } else {
                                answer = retrievalAnswer
                            }
                            await self.typewriterFallback(
                                threadId: threadId,
                                messageId: answerId,
                                finalText: answer.answerText,
                                sources: answer.sources,
                                suggestions: Self.followUpSuggestions(question: question, answer: answer)
                            )
                        }
                    } else if shouldAttemptOllama {
                        if let ollamaText = await Self.awaitTrimmedOllamaText(parallelOllamaTask) {
                            answer = AnswerWithSources(
                                answerText: ollamaText,
                                sources: []
                            )
                        } else if weakRetrieval {
                            answer = AnswerWithSources(
                                answerText: "Unfortunately, I couldn't find a confident answer from your saved sources, and Ollama could not answer right now.",
                                sources: []
                            )
                        } else {
                            answer = retrievalAnswer
                        }
                    } else {
                        // Retrieval remains primary in grounded mode; cancel unused parallel Ollama work.
                        parallelOllamaTask?.cancel()
                    }

                    assistantMessage = ChatMessage(
                        threadId: threadId,
                        role: .assistant,
                        content: answer.answerText,
                        sources: answer.sources,
                        suggestions: Self.followUpSuggestions(question: question, answer: answer),
                        createdAt: Date()
                    )

                    let historyItem = QueryHistoryItem(
                        question: question,
                        answerText: answer.answerText,
                        sources: answer.sources
                    )
                    try? store.insertHistory(item: historyItem)
                    let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    let success = !answer.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    await MainActor.run {
                        self.trackQuery(question: question, success: success, latencyMs: latencyMs)
                    }
                }
            }

            try? store.insertChatMessage(assistantMessage)
            await MainActor.run {
                if self.selectedChatThreadId == threadId {
                    if let idx = self.activeChatMessages.lastIndex(where: { $0.role == .assistant && $0.threadId == threadId }) {
                        self.activeChatMessages[idx] = assistantMessage
                    } else {
                        self.activeChatMessages.append(assistantMessage)
                    }
                }
                self.chatInProgress = false
                self.refreshChatThreads(selectLatestIfNeeded: false)
                self.refreshChatAnalytics()
                if self.selectedChatThreadId == nil {
                    self.selectedChatThreadId = threadId
                }
                self.refreshHistory()
            }
        }
    }

    func refreshChatAnalytics() {
        chatAnalytics = try? store.fetchChatAnalyticsSummary()
        topChatThreadStats = (try? store.fetchTopChatThreadStats(limit: 12)) ?? []
    }

    func dismissAvailableAppUpdate() {
        availableAppUpdate = nil
    }

    func refreshOllamaAvailability() async {
        ollamaAvailability = await OllamaClient.checkAvailability(model: OllamaClient.defaultModel)
    }

    func refreshAppUpdateInfo() async {
        let update = await feedbackReporter.checkForAppUpdate()
        if let update, update.isUpdateAvailable || update.isUpgradeRequired {
            availableAppUpdate = update
        } else {
            availableAppUpdate = nil
        }
    }

    func deleteItem(_ item: KnowledgeItem) {
        try? store.deleteItem(id: item.id)
        refreshItems()
        refreshHistory()
    }

    func itemExists(id: UUID) -> Bool {
        (try? store.itemExists(id: id)) ?? false
    }

    /// Save a URL to the offline knowledge base (embed + index). Used by Web tab "Save to offline".
    func saveURLToOffline(_ url: URL, savedFrom: String = "manual") {
        saveError = nil
        saveSuccess = nil
        let canonical = canonicalizedURLString(url)
        let added = ingestionQueueStore.enqueueIfNeeded(canonicalURL: canonical, savedFrom: savedFrom)
        saveJobState = .queued(url)
        if added {
            saveSuccess = "Queued for offline save."
        } else {
            saveSuccess = "Already queued."
        }
        refreshIngestionQueueMetrics()
        triggerQueueWorker()
    }

    func browserNavigationStarted(tabId: UUID, url: URL) {
        browserSessionService.navigationStarted(tabId: tabId, url: url)
    }

    func browserNavigationFinished(tabId: UUID, url: URL) {
        browserSessionService.navigationFinished(tabId: tabId, url: url)
    }

    func browserScrollUpdated(tabId: UUID, scrollPct: Double) {
        browserSessionService.updateScroll(tabId: tabId, scrollPct: scrollPct)
    }

    func browserTabClosed(tabId: UUID) {
        browserSessionService.close(tabId: tabId)
    }

    func refreshIngestionQueueMetrics() {
        let metrics = ingestionQueueStore.queueMetrics()
        ingestionQueuePendingCount = metrics.pending
        ingestionQueueDeadLetterCount = metrics.deadLetter
        ingestionQueueNextRetrySeconds = metrics.nextInSeconds
    }

    func retryQueuedJobsNow() {
        _ = ingestionQueueStore.forceRetryPendingNow()
        refreshIngestionQueueMetrics()
        triggerQueueWorker()
    }

    func replayDeadLetterJobs() {
        _ = ingestionQueueStore.reviveDeadLetters()
        refreshIngestionQueueMetrics()
        triggerQueueWorker()
    }

    func exportIngestionQueueDiagnostics() -> URL? {
        struct Snapshot: Codable {
            let generatedAt: Date
            let jobs: [IngestionQueueJob]
        }
        let jobs = ingestionQueueStore.listAll()
        let payload = Snapshot(generatedAt: Date(), jobs: jobs)
        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KnowledgeCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("ingestion_queue_diagnostics_\(Int(Date().timeIntervalSince1970)).json")
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    func openCitationSource(url rawURL: String?) -> String? {
        guard let rawURL, let sourceURL = normalizedSourceURL(rawURL) else {
            return "Source cannot be opened: missing or invalid URL."
        }
        if sourceURL.isFileURL {
            let original = sourceURL.standardizedFileURL
            let resolved = fileBookmarkStore.resolveURL(for: original) ?? original
            let didAccess = resolved.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    resolved.stopAccessingSecurityScopedResource()
                }
            }
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                return "File not found at saved location: \(resolved.lastPathComponent)"
            }
            NSWorkspace.shared.activateFileViewerSelecting([resolved])
            guard NSWorkspace.shared.open(resolved) else {
                return "Unable to open file. Re-import it once to grant permission."
            }
            return nil
        }
        guard NSWorkspace.shared.open(sourceURL) else {
            return "Unable to open source: \(sourceURL.absoluteString)"
        }
        return nil
    }

    func trackQuery(question: String, success: Bool, latencyMs: Int) {
        recentQueryLatenciesMs.append(max(0, latencyMs))
        if recentQueryLatenciesMs.count > 100 {
            recentQueryLatenciesMs.removeFirst(recentQueryLatenciesMs.count - 100)
        }
        queryLatencyP95Ms = percentile95(recentQueryLatenciesMs)

        let stats = (try? store.fetchStorageTotals())
        let payload: [String: Any] = [
            "question_length": question.count,
            "query_success": success,
            "query_latency_ms": latencyMs,
            "query_latency_p95_ms": queryLatencyP95Ms,
            "urls_saved_total": stats?.itemsCount ?? savedItems.count,
            "raw_bytes_total": stats?.rawBytesTotal ?? 0,
            "stored_bytes_total": stats?.storedBytesTotal ?? 0
        ]
        feedbackReporter.sendAnalyticsEvent(event: "query_answered", metrics: payload, isConnected: networkMonitor.isConnected)
    }

    private func trackSessionStarted() {
        let stats = (try? store.fetchStorageTotals())
        feedbackReporter.sendAnalyticsEvent(
            event: "session_started",
            metrics: [
                "activated": true,
                "urls_saved_total": stats?.itemsCount ?? 0,
                "raw_bytes_total": stats?.rawBytesTotal ?? 0,
                "stored_bytes_total": stats?.storedBytesTotal ?? 0
            ],
            isConnected: networkMonitor.isConnected
        )
    }

    private func trackURLSaved(item: KnowledgeItem) {
        let stats = (try? store.fetchStorageTotals())
        feedbackReporter.sendAnalyticsEvent(
            event: "url_saved",
            metrics: [
                "activated": true,
                "saved_item_id": item.id.uuidString,
                "saved_item_title": item.title,
                "urls_saved_total": stats?.itemsCount ?? savedItems.count,
                "raw_bytes_total": stats?.rawBytesTotal ?? 0,
                "stored_bytes_total": stats?.storedBytesTotal ?? 0
            ],
            isConnected: networkMonitor.isConnected
        )
    }

    nonisolated private static func normalizeChatQuery(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.replacingOccurrences(of: "wwhat", with: "what", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "i20", with: "i-20", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "uncc", with: "UNC Charlotte", options: .caseInsensitive)
        return text
    }

    nonisolated private static func chatThreadTitle(from question: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New chat" }
        return String(trimmed.prefix(60))
    }

    nonisolated private static func contextualRetrievalQuery(currentQuestion: String, priorMessages: [ChatMessage]) -> String {
        let recentUserTurns = priorMessages
            .filter { $0.role == .user }
            .suffix(2)
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !recentUserTurns.isEmpty else {
            return currentQuestion
        }
        let context = recentUserTurns.joined(separator: " | ")
        return "\(currentQuestion)\nContext: \(context)"
    }

    nonisolated private static func followUpSuggestions(question: String, answer: AnswerWithSources) -> [String] {
        var suggestions: [String] = []
        let q = question.lowercased()

        if q.contains("cost") || q.contains("fee") || q.contains("tuition") || q.contains("i-20") {
            suggestions.append("Break down tuition vs living costs")
            suggestions.append("What is the total amount in the I-20?")
        }

        if !answer.sources.isEmpty {
            suggestions.append("Show exact source lines used")
            if let firstTitle = answer.sources.first?.title, !firstTitle.isEmpty {
                suggestions.append("Summarize \(firstTitle) in 3 bullets")
            }
        }

        suggestions.append("What should I ask next based on this?")
        var deduped: [String] = []
        for item in suggestions where !item.isEmpty {
            if !deduped.contains(item) {
                deduped.append(item)
            }
            if deduped.count == 4 {
                break
            }
        }
        return deduped
    }

    nonisolated private static func shouldUseGeneralConversationPath(question: String, bestScore: Float, useOllama: Bool) -> Bool {
        if isGeneralConversationQuery(question) {
            return true
        }
        guard useOllama else { return false }
        return bestScore < AnswerGenerator.lowConfidenceThreshold && looksLikeOpenDomainQuestion(question)
    }

    nonisolated private static func isGeneralConversationQuery(_ question: String) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        let greetings = [
            "hi", "hello", "hey", "yo", "good morning", "good afternoon", "good evening",
            "how are you", "what's up", "whats up", "thanks", "thank you"
        ]
        if greetings.contains(where: { q == $0 || q.hasPrefix($0 + " ") }) {
            return true
        }
        let conversational = [
            "who are you", "what can you do", "can you help me", "tell me a joke"
        ]
        return conversational.contains(where: { q.contains($0) })
    }

    nonisolated private static func isLocalTimeQuery(_ question: String) -> Bool {
        let q = question.lowercased()
        let keys = [
            "what is today", "today date", "what day is it", "current date",
            "current time", "what time is it", "date and time", "today's date",
            "todays date", "time now", "what is the date today"
        ]
        if keys.contains(where: { q.contains($0) }) {
            return true
        }
        if q.contains("time in ") || q.contains("date in ") || q.contains("time at ") {
            return true
        }
        if q.contains("california time") || q.contains("time in california") {
            return true
        }
        return false
    }

    nonisolated private static func localTimeReply(for question: String) -> String {
        let now = Date()
        let tz = TimeZone.current
        let q = question.lowercased()
        let targetZone = Self.requestedTimeZone(for: q) ?? tz

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = targetZone
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .none

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = targetZone
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .medium

        let dateText = dateFormatter.string(from: now)
        let timeText = timeFormatter.string(from: now)
        let zoneText = targetZone.identifier

        if q.contains("time") && !q.contains("date") && !q.contains("day") {
            return "Current local time: \(timeText) (\(zoneText))."
        }
        if q.contains("date") || q.contains("day") || q.contains("today") {
            return "Today is \(dateText). Current local time is \(timeText) (\(zoneText))."
        }
        return "Current local date and time: \(dateText), \(timeText) (\(zoneText))."
    }

    nonisolated private static func requestedTimeZone(for query: String) -> TimeZone? {
        if query.contains("california") || query.contains("los angeles") || query.contains("la time") || query.contains("pacific time") {
            return TimeZone(identifier: "America/Los_Angeles")
        }
        if query.contains("new york") || query.contains("eastern time") {
            return TimeZone(identifier: "America/New_York")
        }
        if query.contains("texas") || query.contains("central time") || query.contains("chicago") {
            return TimeZone(identifier: "America/Chicago")
        }
        if query.contains("mountain time") || query.contains("denver") {
            return TimeZone(identifier: "America/Denver")
        }
        return nil
    }

    nonisolated private static func looksLikeOpenDomainQuestion(_ question: String) -> Bool {
        let q = question.lowercased()
        let knowledgeBaseTerms = [
            "saved", "source", "citation", "knowledge base", "document", "documents",
            "i-20", "uncc", "unc charlotte", "tuition", "cost"
        ]
        if knowledgeBaseTerms.contains(where: { q.contains($0) }) {
            return false
        }
        let prefixes = ["what", "who", "when", "where", "why", "how", "explain", "tell me"]
        return prefixes.contains(where: { q.hasPrefix($0 + " ") || q == $0 })
    }

    nonisolated private static func shouldPreferKnowledgeBase(
        question: String,
        requestedMode: ChatAnswerMode,
        canUseOllama: Bool
    ) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if isGeneralConversationQuery(q) {
            return false
        }

        let knowledgeBaseSignals = [
            "saved", "source", "sources", "citation", "knowledge base", "document", "documents",
            "pdf", "file", "notes", "in my", "from my", "i-20", "uncc", "unc charlotte", "tuition", "cost"
        ]
        let hasKnowledgeBaseSignal = knowledgeBaseSignals.contains(where: { q.contains($0) })
        if hasKnowledgeBaseSignal {
            return true
        }

        switch requestedMode {
        case .ollama:
            return false
        case .grounded:
            // In grounded mode, prioritize document retrieval by default.
            // Only bypass KB for clear social/opening prompts to avoid losing source-grounded answers.
            if canUseOllama && isLikelySocialPrompt(q) {
                return false
            }
            return true
        }
    }

    nonisolated private static func isLikelySocialPrompt(_ question: String) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let social = [
            "hi", "hello", "hey", "yo", "good morning", "good afternoon", "good evening",
            "how are you", "what's up", "whats up", "thanks", "thank you",
            "who are you", "what can you do", "tell me a joke"
        ]
        return social.contains(where: { q == $0 || q.hasPrefix($0 + " ") })
    }

    nonisolated private static func shouldTryOllamaAfterRetrieval(answer: AnswerWithSources, bestScore: Float) -> Bool {
        if bestScore < AnswerGenerator.lowConfidenceThreshold {
            return true
        }
        let text = answer.answerText.lowercased()
        let weakPhrases = [
            "no relevant content found",
            "not very confident",
            "couldn't find",
            "cannot find",
            "can't find",
            "unfortunately"
        ]
        return weakPhrases.contains(where: { text.contains($0) })
    }

    nonisolated private static func awaitTrimmedOllamaText(_ task: Task<String?, Never>?) async -> String? {
        guard let task else { return nil }
        guard let raw = await task.value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func generalOllamaSystemPrompt() -> String {
        """
        You are a friendly, concise assistant for Save the Knowledge.
        Prioritize answers grounded in the user's saved knowledge base when available.
        If you are giving a general answer outside the knowledge base, state that briefly.
        Answer clearly and directly using short paragraphs or bullets when helpful.
        """
    }

    nonisolated private static func generalFallbackReply(for question: String) -> String {
        let q = question.lowercased()
        if q.contains("hi") || q.contains("hello") || q.contains("hey") {
            return "Hi! I can help with general questions and your saved knowledge-base documents. What would you like to know?"
        }
        if q.contains("how are you") {
            return "Doing well. I can help with general questions and also answer from your saved documents with sources."
        }
        return "I can help with general questions and with citation-backed answers from your saved documents. Ask me anything."
    }

    nonisolated private static func generalConversationSuggestions() -> [String] {
        [
            "What can you do?",
            "Summarize my latest saved topics",
            "Ask me a follow-up question"
        ]
    }

    nonisolated private static func generateGeneralAssistantMessage(
        threadId: UUID,
        question: String,
        streamWithUI: @escaping @Sendable (_ messageId: UUID, _ onToken: @escaping @Sendable () async -> Void) async -> String?,
        typewriterFallback: @escaping @Sendable (_ messageId: UUID, _ text: String, _ suggestions: [String]) async -> Void
    ) async -> ChatMessage {
        let messageId = UUID()
        let fallback = generalFallbackReply(for: question)
        let suggestions = generalConversationSuggestions()
        let streamed = await streamWithUI(messageId) { }
        let finalText: String
        if let streamed, !streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalText = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            await typewriterFallback(messageId, fallback, suggestions)
            finalText = fallback
        }
        return ChatMessage(
            id: messageId,
            threadId: threadId,
            role: .assistant,
            content: finalText,
            sources: [],
            suggestions: suggestions,
            createdAt: Date()
        )
    }

    private func updateStreamingAssistantContent(
        threadId: UUID,
        messageId: UUID,
        append token: String? = nil,
        overwrite: String? = nil,
        sources: [SourceRef]? = nil,
        suggestions: [String]? = nil
    ) {
        guard selectedChatThreadId == threadId else { return }
        guard let idx = activeChatMessages.firstIndex(where: { $0.id == messageId }) else { return }
        if let overwrite {
            activeChatMessages[idx].content = overwrite
        } else if let token {
            activeChatMessages[idx].content += token
        }
        if let sources {
            activeChatMessages[idx].sources = sources
        }
        if let suggestions {
            activeChatMessages[idx].suggestions = suggestions
        }
    }

    private func typewriterFallback(
        threadId: UUID,
        messageId: UUID,
        finalText: String,
        sources: [SourceRef],
        suggestions: [String]
    ) async {
        let characters = Array(finalText)
        var cursor = 0
        let chunkSize = 6
        while cursor < characters.count {
            let next = min(characters.count, cursor + chunkSize)
            let chunk = String(characters[cursor..<next])
            await MainActor.run {
                self.updateStreamingAssistantContent(threadId: threadId, messageId: messageId, append: chunk)
            }
            cursor = next
            try? await Task.sleep(nanoseconds: 35_000_000)
        }
        await MainActor.run {
            self.updateStreamingAssistantContent(
                threadId: threadId,
                messageId: messageId,
                overwrite: finalText,
                sources: sources,
                suggestions: suggestions
            )
        }
    }

    private func autoSaveVisitedURLIfNeeded(_ url: URL) {
        guard autoSaveVisitedPages else { return }
        guard !isSaveInProgress else { return }
        let canonical = canonicalizedURLString(url)
        guard !canonical.isEmpty, !autoSavedCanonicalURLs.contains(canonical) else { return }
        autoSavedCanonicalURLs.insert(canonical)
        saveURLToOffline(url, savedFrom: "auto")
    }

    nonisolated private static func evaluateCaptureDecisionFromDefaults(_ input: CaptureInput) -> CaptureDecision {
        let autoSaveVisitedPages = UserDefaults.standard.object(forKey: Self.autoSaveVisitedPagesKey) as? Bool ?? true
        let autoSaveDwellSeconds = UserDefaults.standard.object(forKey: Self.autoSaveDwellSecondsKey) as? Double ?? 20.0
        let autoSaveScrollPercent = UserDefaults.standard.object(forKey: Self.autoSaveScrollPercentKey) as? Double ?? 20.0
        let autoSaveAllowDomains = UserDefaults.standard.string(forKey: Self.autoSaveAllowDomainsKey) ?? ""
        let autoSaveDenyDomains = UserDefaults.standard.string(forKey: Self.autoSaveDenyDomainsKey) ?? ""

        guard autoSaveVisitedPages else {
            return CaptureDecision(shouldAutoSave: false, reason: "disabled")
        }
        let defaultDecision = DefaultCapturePolicyEngine().evaluate(
            CaptureInput(
                url: input.url,
                dwellMs: input.dwellMs,
                scrollPct: input.scrollPct,
                isManualSave: input.isManualSave
            )
        )
        guard defaultDecision.shouldAutoSave else { return defaultDecision }

        if input.dwellMs < Int(max(1, autoSaveDwellSeconds) * 1000) {
            return CaptureDecision(shouldAutoSave: false, reason: "below_custom_dwell")
        }
        if input.scrollPct < autoSaveScrollPercent {
            return CaptureDecision(shouldAutoSave: false, reason: "below_custom_scroll")
        }
        let host = input.url.host?.lowercased() ?? ""
        let allow = parseDomainList(autoSaveAllowDomains)
        let deny = parseDomainList(autoSaveDenyDomains)
        if !allow.isEmpty && !allow.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return CaptureDecision(shouldAutoSave: false, reason: "not_allowlisted")
        }
        if deny.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return CaptureDecision(shouldAutoSave: false, reason: "denylisted")
        }
        return CaptureDecision(shouldAutoSave: true, reason: "accepted")
    }

    nonisolated private static func parseDomainList(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func persistSnapshotsAndMetadata(for item: KnowledgeItem, sourceURL: URL, savedFrom: String) async {
        let canonical = canonicalizedURLString(sourceURL)
        do {
            let reader = try snapshotService.saveReaderText(item.rawContent, canonicalURL: canonical)
            try store.insertSnapshot(
                itemId: item.id,
                type: "reader",
                path: reader.path,
                sizeBytes: reader.sizeBytes,
                contentHash: reader.hash
            )
            let full = await snapshotService.saveBestEffortFullSnapshot(
                url: sourceURL,
                fallbackTitle: item.title,
                fallbackBody: item.rawContent
            )
            if let full {
                try store.insertSnapshot(
                    itemId: item.id,
                    type: "full",
                    path: full.path,
                    sizeBytes: full.sizeBytes,
                    contentHash: full.hash
                )
            }
            try store.updateItemCaptureMetadata(
                itemId: item.id,
                canonicalURL: canonical,
                savedFrom: savedFrom,
                savedAt: Date(),
                fullSnapshotPath: full?.path
            )
        } catch {
            AppLogger.warning("Snapshot metadata persistence failed for \(item.id): \(error.localizedDescription)")
        }
        Task.detached(priority: .utility) { [weak snapshotService] in
            _ = snapshotService?.enforceRetention()
        }
    }

    private func triggerQueueWorker() {
        guard queueWorkerTask == nil else { return }
        queueWorkerTask = Task { @MainActor in
            await runQueueWorker()
            queueWorkerTask = nil
        }
    }

    private func runQueueWorker() async {
        while !Task.isCancelled {
            guard let job = ingestionQueueStore.nextReadyJob() else {
                guard let wait = ingestionQueueStore.secondsUntilNextReady(), wait > 0 else {
                    return
                }
                let ns = UInt64(min(wait, 300) * 1_000_000_000.0)
                try? await Task.sleep(nanoseconds: ns)
                continue
            }

            guard let url = URL(string: job.canonicalURL) else {
                _ = ingestionQueueStore.markRetryOrDeadLetter(
                    jobId: job.id,
                    errorMessage: "Invalid URL in queue",
                    maxAttempts: 1
                )
                feedbackReporter.reportIssue(
                    category: "ingestion_queue_invalid_url",
                    severity: "error",
                    message: "Queue item had invalid URL and was dead-lettered.",
                    details: job.canonicalURL,
                    isConnected: networkMonitor.isConnected
                )
                refreshIngestionQueueMetrics()
                continue
            }

            isSaveInProgress = true
            saveJobState = .indexing(url)
            do {
                guard !url.isFileURL else {
                    let result = ingestionQueueStore.markRetryOrDeadLetter(
                        jobId: job.id,
                        errorMessage: "Local file jobs are no longer supported",
                        maxAttempts: 1
                    )
                    isSaveInProgress = false
                    refreshIngestionQueueMetrics()
                    if !result.willRetry {
                        saveError = "Skipped unsupported local file job."
                        saveJobState = .failed("Local file jobs are unsupported")
                    }
                    continue
                }
                let item = try await pipeline.ingest(url: url)
                await persistSnapshotsAndMetadata(for: item, sourceURL: url, savedFrom: job.savedFrom)
                ingestionQueueStore.markSuccess(jobId: job.id)
                refreshItems()
                isSaveInProgress = false
                saveSuccess = "Saved: \(item.title)"
                saveJobState = .ready(item.title)
                refreshIngestionQueueMetrics()
                trackURLSaved(item: item)
            } catch {
                let result = ingestionQueueStore.markRetryOrDeadLetter(
                    jobId: job.id,
                    errorMessage: error.localizedDescription
                )
                isSaveInProgress = false
                refreshIngestionQueueMetrics()
                if result.willRetry {
                    saveJobState = .queued(url)
                    AppLogger.warning("Queue retry scheduled for \(url.absoluteString)")
                } else {
                    saveError = "Dead-lettered after retries: \(error.localizedDescription)"
                    saveJobState = .failed(error.localizedDescription)
                    AppLogger.error("Queue dead-lettered \(url.absoluteString): \(error.localizedDescription)")
                    feedbackReporter.reportIssue(
                        category: "ingestion_queue_dead_letter",
                        severity: "error",
                        message: "Queue item exhausted retries and was dead-lettered.",
                        details: "\(url.absoluteString) :: \(error.localizedDescription)",
                        isConnected: networkMonitor.isConnected
                    )
                }
            }
        }
    }

    private func canonicalizedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        if let host = components.host {
            components.host = host.lowercased()
        }
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let filtered = queryItems.filter { item in
                let key = item.name.lowercased()
                return !key.hasPrefix("utm_") && key != "fbclid" && key != "gclid"
            }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private func percentile95(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int(Double(sorted.count - 1) * 0.95)
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    private func normalizedSourceURL(_ raw: String) -> URL? {
        if let parsed = URL(string: raw), parsed.scheme != nil {
            return parsed
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw)
        }
        return nil
    }
}
