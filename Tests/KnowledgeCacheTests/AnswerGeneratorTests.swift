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

    func testProfileSDEExperienceQuestion() {
        let r = makeResult(
            score: 0.6,
            chunkText: "Software Engineer with 2+ years of experience designing scalable systems and backend services.",
            title: "Dhanush Resume"
        )
        let out = AnswerGenerator.generate(results: [r], query: "does dhanush kumar has any experience in the sde")
        XCTAssertTrue(out.answerText.lowercased().contains("yes"))
        XCTAssertTrue(out.answerText.lowercased().contains("experience"))
    }

    func testProfileResumeQuestion() {
        let r = makeResult(
            score: 0.5,
            chunkText: "Skills and Resume. Download resume for full profile.",
            title: "Dhanush Resume"
        )
        let out = AnswerGenerator.generate(results: [r], query: "does dhanush kumar has the resume")
        XCTAssertTrue(out.answerText.lowercased().contains("yes"))
        XCTAssertTrue(out.answerText.lowercased().contains("resume"))
    }

    func testProfileContactQuestion() {
        let r = makeResult(
            score: 0.5,
            chunkText: "Contact: danthara@charlotte.edu and +1 (704) 930-3938. LinkedIn: https://linkedin.com/in/dhanush",
            title: "Dhanush Resume"
        )
        let out = AnswerGenerator.generate(results: [r], query: "what are dhanushkumar contact details")
        XCTAssertTrue(out.answerText.lowercased().contains("contact details"))
        XCTAssertTrue(out.answerText.lowercased().contains("danthara@charlotte.edu"))
        XCTAssertTrue(out.answerText.lowercased().contains("704"))
    }

    func testProfileContactQuestionUsesLowerRankedSourceEvidence() {
        let topWebsite = makeResult(
            score: 0.92,
            chunkText: "Portfolio profile and projects overview without direct email text.",
            title: "A Dhanush Kumar Portfolio"
        )
        let lowerResume = makeResult(
            score: 0.60,
            chunkText: "Contact: danthara@charlotte.edu and +1 (704) 930-3938.",
            title: "Dhanush Resume"
        )
        let out = AnswerGenerator.generate(results: [topWebsite, lowerResume], query: "what are dhanushkumar contact details")
        XCTAssertTrue(out.answerText.lowercased().contains("danthara@charlotte.edu"))
        XCTAssertTrue(out.answerText.lowercased().contains("704"))
    }

    func testFeedbackPayloadWithNilEmailIsValidJSON() throws {
        let item = FeedbackItem(
            id: "id1",
            message: "hello",
            email: nil,
            type: "bug",
            appVersion: "1",
            osVersion: "1",
            timestamp: "2026-02-14T00:00:00Z"
        )

        let body: [String: Any] = [
            "id": item.id,
            "message": item.message,
            "email": item.email ?? NSNull(),
            "type": item.type,
            "app_version": item.appVersion,
            "os_version": item.osVersion,
            "timestamp": item.timestamp
        ]

        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testFeedbackPayloadWithEmailStringPreservesEmail() throws {
        let item = FeedbackItem(
            id: "id2",
            message: "hello",
            email: "me@example.com",
            type: "bug",
            appVersion: "1",
            osVersion: "1",
            timestamp: "2026-02-14T00:00:00Z"
        )

        let body: [String: Any] = [
            "id": item.id,
            "message": item.message,
            "email": item.email ?? NSNull(),
            "type": item.type,
            "app_version": item.appVersion,
            "os_version": item.osVersion,
            "timestamp": item.timestamp
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["email"] as? String, "me@example.com")
    }
}
