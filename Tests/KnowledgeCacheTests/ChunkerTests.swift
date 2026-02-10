//
//  ChunkerTests.swift
//  KnowledgeCacheTests
//
//  Truncation behavior: maxChunks limit.
//

import XCTest
@testable import KnowledgeCache

final class ChunkerTests: XCTestCase {

    func testChunkRespectsMaxChunks() {
        let long = String(repeating: "a. ", count: 400)
        let chunks = Chunker.chunk(text: long, maxChars: 100, maxChunks: 5)
        XCTAssertLessThanOrEqual(chunks.count, 5)
    }

    func testChunkEmptyReturnsEmpty() {
        let chunks = Chunker.chunk(text: "   \n\n  ", maxChunks: 10)
        XCTAssertTrue(chunks.isEmpty)
    }

    func testChunkShortTextSingleChunk() {
        let chunks = Chunker.chunk(text: "Short.", maxChars: 600, maxChunks: 0)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].1, "Short.")
    }
}
