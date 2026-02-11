//
//  AppState.swift
//  KnowledgeCache
//
//  Shared DB, store, embedding, pipelines. Created once at launch.
//

import Foundation
import SwiftUI

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
                self?.feedbackReporter.flushPendingFeedback(isConnected: self?.networkMonitor.isConnected ?? false)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let connected = networkMonitor.isConnected
            AppLogger.info("Feedback: initial flush check connected=\(connected)")
            feedbackReporter.flushPendingFeedback(isConnected: connected)
            feedbackReporter.sendAnalyticsIfNeeded(savesCount: (try? store.fetchAllItems())?.count ?? 0, isConnected: connected)
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
        let pipeline = pipeline
        Task.detached(priority: .userInitiated) {
            do {
                let item = try await pipeline.ingest(url: url)
                await MainActor.run {
                    self.refreshItems()
                    self.isSaveInProgress = false
                    self.saveSuccess = "Saved: \(item.title)"
                }
            } catch {
                await MainActor.run {
                    self.saveError = error.localizedDescription
                    self.isSaveInProgress = false
                }
            }
        }
    }
}
