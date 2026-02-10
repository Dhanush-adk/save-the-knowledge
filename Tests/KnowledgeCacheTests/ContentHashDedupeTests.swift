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
}
