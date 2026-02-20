//
//  SaveAndAskIntegrationTests.swift
//  KnowledgeCacheTests
//
//  Integration: save adhanushkumar.com, ask about Dhanush Kumar, print answer.
//

import XCTest
@testable import KnowledgeCache

@MainActor
final class SaveAndAskIntegrationTests: XCTestCase {

    func testSaveAdhanushkumarAndAskAboutDhanushKumar() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeCacheIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.db").path
        let db = Database(path: dbPath)
        try db.open()
        defer { db.close() }

        let store = KnowledgeStore(db: db)
        let embedding = MockEmbeddingService()
        let pipeline = IngestionPipeline(store: store, embedding: embedding)
        let search = SemanticSearch(store: store, embedding: embedding)

        let url = URL(string: "https://adhanushkumar.com/")!
        let item: KnowledgeItem
        do {
            item = try await pipeline.ingest(url: url)
        } catch {
            XCTFail("Ingest failed: \(error)")
            return
        }

        XCTAssertFalse(item.rawContent.isEmpty, "Saved page should have content")
        XCTAssertFalse(item.title.isEmpty, "Saved page should have a title")

        let outcome = search.search(query: "Dhanush Kumar", topK: 10)
        guard case .results(let results) = outcome else {
            if case .reindexRequired = outcome {
                XCTFail("Unexpected reindex required")
            }
            return
        }

        let answer = AnswerGenerator.generate(results: results, query: "Dhanush Kumar")

        // Print so we can capture from test output
        print("--- SAVE_AND_ASK_ANSWER_START ---")
        print(answer.answerText)
        print("--- SAVE_AND_ASK_ANSWER_END ---")
        print("--- SAVE_AND_ASK_SOURCES_START ---")
        for s in answer.sources {
            print("\(s.title) | \(s.url ?? "")")
        }
        print("--- SAVE_AND_ASK_SOURCES_END ---")
    }

    /// Run extraction pipeline for adhanushkumar.com and print everything the backend extracted (title, raw body, all chunks).
    func testExtractAdhanushkumarAndPrintAllExtracted() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeCacheExtract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.db").path
        let db = Database(path: dbPath)
        try db.open()
        defer { db.close() }

        let store = KnowledgeStore(db: db)
        let embedding = MockEmbeddingService()
        let pipeline = IngestionPipeline(store: store, embedding: embedding)

        let url = URL(string: "https://adhanushkumar.com/")!
        let item: KnowledgeItem
        do {
            item = try await pipeline.ingest(url: url)
        } catch {
            XCTFail("Ingest failed: \(error)")
            return
        }

        print("--- EXTRACTED_TITLE ---")
        print(item.title)
        print("--- EXTRACTED_RAW_BODY ---")
        print(item.rawContent)
        print("--- EXTRACTED_RAW_BODY_END ---")

        let chunkPairs = (try? store.fetchChunksForItem(knowledgeItemId: item.id)) ?? []
        print("--- EXTRACTED_CHUNKS_COUNT ---")
        print(chunkPairs.count)
        print("--- EXTRACTED_CHUNKS_START ---")
        for (idx, pair) in chunkPairs.enumerated() {
            print("--- CHUNK \(idx + 1) ---")
            print(pair.text)
        }
        print("--- EXTRACTED_CHUNKS_END ---")
    }

    func testSearchPrefersResumeContentForResumeQuery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeCacheResumeQuery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = Database(path: tempDir.appendingPathComponent("test.db").path)
        try db.open()
        defer { db.close() }

        let store = KnowledgeStore(db: db)
        let embedding = MockEmbeddingService()
        let pipeline = IngestionPipeline(store: store, embedding: embedding)
        let search = SemanticSearch(store: store, embedding: embedding)

        _ = try pipeline.ingestPastedText("""
        Dhanush Resume
        Software Engineer with 2+ years experience in SDE and backend systems.
        Resume and portfolio available.
        """)
        _ = try pipeline.ingestPastedText("""
        I20 Document
        Immigration form and student eligibility details.
        """)

        let outcome = search.search(query: "does dhanush kumar has the resume", topK: 3)
        guard case .results(let results) = outcome else {
            XCTFail("Expected results")
            return
        }
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.title, "Dhanush Resume")
    }

    func testSearchHandlesMergedNameTokenForContactQuery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeCacheMergedNameQuery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = Database(path: tempDir.appendingPathComponent("test.db").path)
        try db.open()
        defer { db.close() }

        let store = KnowledgeStore(db: db)
        let embedding = MockEmbeddingService()
        let pipeline = IngestionPipeline(store: store, embedding: embedding)
        let search = SemanticSearch(store: store, embedding: embedding)

        _ = try pipeline.ingestPastedText("""
        Dhanush Resume
        Contact: danthara@charlotte.edu and +1 (704) 930-3938.
        """)
        _ = try pipeline.ingestPastedText("""
        Random Website
        A generic content page without contact details.
        """)

        let outcome = search.search(query: "what are dhanushkumar contact details", topK: 3)
        guard case .results(let results) = outcome else {
            XCTFail("Expected results")
            return
        }
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.title, "Dhanush Resume")
    }
}
