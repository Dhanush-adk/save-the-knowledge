//
//  AnswerGeneratorTests.swift
//  KnowledgeCacheTests
//
//  Deterministic outputs and low-confidence path.
//

import XCTest
@testable import KnowledgeCache

final class AnswerGeneratorTests: XCTestCase {

    func makeResult(score: Float, chunkText: String, title: String) -> RetrievalResult {
        RetrievalResult(
            chunkText: chunkText,
            score: score,
            knowledgeItemId: UUID(),
            title: title,
            url: nil,
            sourceDisplay: title
        )
    }

    func testEmptyResults() {
        let out = AnswerGenerator.generate(results: [], query: "")
        XCTAssertEqual(out.sources.count, 0)
        XCTAssertTrue(out.answerText.contains("No relevant content"))
    }

    func testLowConfidencePath() {
        let low = makeResult(score: 0.1, chunkText: "Some text.", title: "Source A")
        let out = AnswerGenerator.generate(results: [low], query: "query")
        XCTAssertTrue(out.answerText.contains("not very confident") || out.answerText.contains("Closest sources"), "Low-confidence path should show intro or sources")
        XCTAssertFalse(out.sources.isEmpty)
    }

    func testDeterminismSameInput() {
        let r = makeResult(score: 0.9, chunkText: "First sentence. Second sentence. Third sentence.", title: "T")
        let a = AnswerGenerator.generate(results: [r], query: "sentence")
        let b = AnswerGenerator.generate(results: [r], query: "sentence")
        XCTAssertEqual(a.answerText, b.answerText)
        XCTAssertEqual(a.sources.count, b.sources.count)
    }

    func testHighConfidenceProducesAnswer() {
        let r = makeResult(score: 0.8, chunkText: "This is a long enough sentence that fits the bounds. So does this one.", title: "T")
        let out = AnswerGenerator.generate(results: [r], query: "sentence")
        XCTAssertFalse(out.answerText.contains("don't have enough"))
        XCTAssertFalse(out.sources.isEmpty)
    }
}
