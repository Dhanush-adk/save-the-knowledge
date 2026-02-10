//
//  ForeignKeyCascadeTests.swift
//  KnowledgeCacheTests
//
//  Delete item cascades to chunks.
//

import XCTest
@testable import KnowledgeCache

final class ForeignKeyCascadeTests: XCTestCase {

    var db: Database!
    var store: KnowledgeStore!

    override func setUp() {
        super.setUp()
        let path = NSTemporaryDirectory() + "test_fk_\(UUID().uuidString).db"
        db = Database(path: path)
        try? db.open()
        store = KnowledgeStore(db: db)
    }

    override func tearDown() {
        db?.close()
        super.tearDown()
    }

    func testDeleteItemRemovesChunks() throws {
        let item = KnowledgeItem(title: "T", rawContent: "C", sourceDisplay: "P")
        try store.insert(item: item, chunks: [("chunk1", [Float](repeating: 0, count: 512))])
        let chunksBefore = try store.fetchAllChunks()
        XCTAssertEqual(chunksBefore.count, 1)
        try store.deleteItem(id: item.id)
        let chunksAfter = try store.fetchAllChunks()
        XCTAssertEqual(chunksAfter.count, 0)
    }
}
