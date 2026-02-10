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
}
