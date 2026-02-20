//
//  ContentHashDedupeTests.swift
//  KnowledgeCacheTests
//
//  Dedupe by content_hash: same normalized content returns existing item.
//

import XCTest
@testable import KnowledgeCache

final class ContentHashDedupeTests: XCTestCase {

    var db: Database!
    var store: KnowledgeStore!

    override func setUp() {
        super.setUp()
        let path = NSTemporaryDirectory() + "test_dedupe_\(UUID().uuidString).db"
        db = Database(path: path)
        try? db.open()
        store = KnowledgeStore(db: db)
    }

    override func tearDown() {
        db?.close()
        super.tearDown()
    }

    func testFindByContentHashAfterInsert() throws {
        let hash = "abc123"
        let item = KnowledgeItem(
            title: "T",
            rawContent: "body",
            sourceDisplay: "Pasted",
            contentHash: hash
        )
        try store.insert(item: item, chunks: [("body", [Float](repeating: 0, count: 512))])
        let found = try store.findByContentHash(hash)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.contentHash, hash)
    }

    func testFindByContentHashMissingReturnsNil() throws {
        let found = try store.findByContentHash("nonexistent")
        XCTAssertNil(found)
    }

    func testFTSReturnsInsertedChunk() throws {
        let item = KnowledgeItem(
            title: "Swift Notes",
            rawContent: "Swift concurrency notes",
            sourceDisplay: "Pasted"
        )
        try store.insert(item: item, chunks: [("Async await actor isolation patterns", [Float](repeating: 0, count: 512))])
        let hits = try store.searchChunksFTS(query: "actor isolation", limit: 5)
        XCTAssertFalse(hits.isEmpty)
    }

    func testPageVisitAndSnapshotPersistence() throws {
        let item = KnowledgeItem(
            title: "Snapshot Item",
            rawContent: "Offline snapshot body",
            sourceDisplay: "Pasted"
        )
        try store.insert(item: item, chunks: [("offline snapshot", [Float](repeating: 0, count: 512))])

        let visit = KnowledgeStore.PageVisit(
            id: UUID(),
            url: "https://example.com/article",
            tabId: UUID(),
            startedAt: Date().addingTimeInterval(-42),
            endedAt: Date(),
            dwellMs: 42_000,
            scrollPct: 75
        )
        XCTAssertNoThrow(try store.insertPageVisit(visit))
        XCTAssertNoThrow(try store.insertSnapshot(
            itemId: item.id,
            type: "reader",
            path: "/tmp/reader.txt",
            sizeBytes: 120,
            contentHash: "abc"
        ))
        XCTAssertNoThrow(try store.updateItemCaptureMetadata(
            itemId: item.id,
            canonicalURL: "https://example.com/article",
            savedFrom: "auto",
            savedAt: Date(),
            fullSnapshotPath: "/tmp/full.html"
        ))
    }

    func testIngestionQueueRetryAndDeadLetter() {
        let subpath = "KnowledgeCache/test_ingestion_queue_\(UUID().uuidString).json"
        let queue = IngestionQueueStore(appSupportSubpath: subpath)
        XCTAssertTrue(queue.enqueueIfNeeded(canonicalURL: "https://example.com/a", savedFrom: "manual"))
        XCTAssertFalse(queue.enqueueIfNeeded(canonicalURL: "https://example.com/a", savedFrom: "manual"))

        guard let job = queue.nextReadyJob(now: Date()) else {
            XCTFail("Expected ready job")
            return
        }
        let retry = queue.markRetryOrDeadLetter(jobId: job.id, errorMessage: "network")
        XCTAssertTrue(retry.willRetry)
        XCTAssertNotNil(retry.nextAttemptAt)

        let dead = queue.markRetryOrDeadLetter(jobId: job.id, errorMessage: "network", maxAttempts: 2)
        XCTAssertFalse(dead.willRetry)
        let metrics = queue.queueMetrics()
        XCTAssertEqual(metrics.pending, 0)
        XCTAssertEqual(metrics.deadLetter, 1)
    }

    func testSnapshotRetentionPrunesOldAndLargeFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotRetention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = SnapshotService(baseURL: root, baseDirName: "snapshots")
        let oldDate = Date().addingTimeInterval(-120 * 86_400)
        for i in 0..<4 {
            let saved = try service.saveReaderText(String(repeating: "x", count: 100 + i), canonicalURL: "https://example.com/\(i)")
            let url = URL(fileURLWithPath: saved.path)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }
        _ = try service.saveReaderText(String(repeating: "y", count: 5000), canonicalURL: "https://example.com/new")

        let removed = service.enforceRetention(maxFiles: 2, maxBytes: 4000, maxAgeDays: 30)
        XCTAssertGreaterThan(removed, 0)
    }

    func testQueueReviveDeadLettersAndForceRetryNow() {
        let subpath = "KnowledgeCache/test_ingestion_queue_revive_\(UUID().uuidString).json"
        let queue = IngestionQueueStore(appSupportSubpath: subpath)
        _ = queue.enqueueIfNeeded(canonicalURL: "https://example.com/retry", savedFrom: "manual")
        guard let job = queue.nextReadyJob(now: Date()) else {
            XCTFail("Expected queued job")
            return
        }
        _ = queue.markRetryOrDeadLetter(jobId: job.id, errorMessage: "err", maxAttempts: 1)
        XCTAssertEqual(queue.queueMetrics().deadLetter, 1)

        let revived = queue.reviveDeadLetters()
        XCTAssertEqual(revived, 1)
        XCTAssertEqual(queue.queueMetrics().deadLetter, 0)
        XCTAssertEqual(queue.queueMetrics().pending, 1)

        _ = queue.forceRetryPendingNow(now: Date().addingTimeInterval(-1))
        _ = queue.markRetryOrDeadLetter(jobId: job.id, errorMessage: "err")
        let moved2 = queue.forceRetryPendingNow()
        XCTAssertGreaterThanOrEqual(moved2, 0)
    }
}
