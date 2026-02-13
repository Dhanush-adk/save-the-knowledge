//
//  AppState.swift
//  KnowledgeCache
//
//  Shared DB, store, embedding, pipelines. Created once at launch.
//

import Foundation
import SwiftUI

enum SaveJobState: Equatable {
    case idle
    case queued(URL)
    case indexing(URL)
    case ready(String)
    case failed(String)
}

@MainActor
final class AppState: ObservableObject {
    let db: Database
    let store: KnowledgeStore
    let embedding: EmbeddingService
    let pipeline: IngestionPipeline
    let search: SemanticSearch
    let reindexController: ReindexController
    let networkMonitor: NetworkMonitor
    let feedbackReporter: FeedbackReporter

    @Published var savedItems: [KnowledgeItem] = []
    @Published var reindexInProgress = false
    @Published var reindexError: String?
    @Published var historyItems: [QueryHistoryItem] = []
    @Published var isSaveInProgress = false
    @Published var saveError: String?
    @Published var searchInProgress = false
    @Published var lastAnswer: AnswerWithSources?
    @Published var searchError: String?
    @Published var saveSuccess: String?
    @Published var saveJobState: SaveJobState = .idle
    @Published var queryLatencyP95Ms: Int = 0

    private var recentQueryLatenciesMs: [Int] = []

    init() {
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
        self.feedbackReporter = FeedbackReporter(pendingStore: pendingStore)
        networkMonitor.onBecameConnected = { [weak self] in
            Task { @MainActor in
                let connected = self?.networkMonitor.isConnected ?? false
                self?.feedbackReporter.emitQueueHealthEvent(reason: "network_became_online", isConnected: connected)
                self?.feedbackReporter.flushPendingFeedback(isConnected: connected)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let connected = networkMonitor.isConnected
            AppLogger.info("Feedback: initial flush check connected=\(connected)")
            feedbackReporter.emitQueueHealthEvent(reason: "app_launch", isConnected: connected)
            feedbackReporter.flushPendingFeedback(isConnected: connected)
            feedbackReporter.sendAnalyticsIfNeeded(savesCount: (try? store.fetchAllItems())?.count ?? 0, isConnected: connected)
            trackSessionStarted()
        }
        AppLogger.info("App started; embedding available=\(embedding.isAvailable)")
    }

    func optimizeStorage() {
        try? store.optimizeStorage()
    }

    func reindexAll() {
        reindexError = nil
        reindexInProgress = true
        let controller = reindexController
        Task.detached(priority: .userInitiated) {
            do {
                try controller.reindexAll { _, _ in }
                await MainActor.run {
                    self.reindexInProgress = false
                }
            } catch {
                await MainActor.run {
                    self.reindexError = error.localizedDescription
                    self.reindexInProgress = false
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

    func deleteItem(_ item: KnowledgeItem) {
        try? store.deleteItem(id: item.id)
        refreshItems()
        refreshHistory()
    }

    func itemExists(id: UUID) -> Bool {
        (try? store.itemExists(id: id)) ?? false
    }

    /// Save a URL to the offline knowledge base (embed + index). Used by Web tab "Save to offline".
    func saveURLToOffline(_ url: URL) {
        saveError = nil
        saveSuccess = nil
        isSaveInProgress = true
        saveJobState = .queued(url)
        let pipeline = pipeline
        Task.detached(priority: .userInitiated) {
            do {
                await MainActor.run {
                    self.saveJobState = .indexing(url)
                }
                let item = try await pipeline.ingest(url: url)
                await MainActor.run {
                    self.refreshItems()
                    self.isSaveInProgress = false
                    self.saveSuccess = "Saved: \(item.title)"
                    self.saveJobState = .ready(item.title)
                    self.trackURLSaved(item: item)
                }
            } catch {
                await MainActor.run {
                    self.saveError = error.localizedDescription
                    self.isSaveInProgress = false
                    self.saveJobState = .failed(error.localizedDescription)
                }
            }
        }
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

    private func percentile95(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int(Double(sorted.count - 1) * 0.95)
        return sorted[max(0, min(index, sorted.count - 1))]
    }
}
