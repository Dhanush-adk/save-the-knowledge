//
//  QueueStorePrivacyTests.swift
//  KnowledgeCacheTests
//
//  Verifies issue/analytics pending queues are encrypted at rest and migrate legacy plaintext.
//

import XCTest
@testable import KnowledgeCache

final class QueueStorePrivacyTests: XCTestCase {

    func testPendingIssueStoreMigratesLegacyPlaintextToEncryptedPayload() throws {
        let filename = "pending_issues_test_\(UUID().uuidString).json"
        let fileURL = queueFileURL(filename: filename)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let legacy = [
            PendingIssueItem(
                id: UUID().uuidString,
                category: "test",
                severity: "warning",
                message: "legacy issue message",
                details: "legacy details",
                appVersion: "1.0",
                osVersion: "macOS",
                installId: "install-1",
                sessionId: "session-1",
                timestamp: "2026-01-01T00:00:00.000Z",
                attemptCount: 0,
                lastError: nil
            )
        ]
        let legacyData = try JSONEncoder().encode(legacy)
        try legacyData.write(to: fileURL, options: .atomic)

        let store = PendingIssueStore(filename: filename)
        let loaded = store.synchronouslyLoad()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.message, "legacy issue message")

        let rewritten = try Data(contentsOf: fileURL)
        let rewrittenString = String(data: rewritten, encoding: .utf8) ?? ""
        XCTAssertFalse(rewrittenString.contains("legacy issue message"))
    }

    func testPendingAnalyticsStoreWritesEncryptedPayload() throws {
        let filename = "pending_analytics_test_\(UUID().uuidString).json"
        let fileURL = queueFileURL(filename: filename)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PendingAnalyticsStore(filename: filename)
        store.append(
            PendingAnalyticsItem(
                id: UUID().uuidString,
                bodyJSON: "{\"event\":\"query_answered\",\"message\":\"sensitive\"}",
                timestamp: "2026-01-01T00:00:00.000Z",
                attemptCount: 0,
                lastError: nil
            )
        )

        let loaded = store.synchronouslyLoad()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertTrue(loaded.first?.bodyJSON.contains("query_answered") == true)

        let stored = try Data(contentsOf: fileURL)
        let storedString = String(data: stored, encoding: .utf8) ?? ""
        XCTAssertFalse(storedString.contains("query_answered"))
        XCTAssertFalse(storedString.contains("sensitive"))
    }

    private func queueFileURL(filename: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KnowledgeCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(filename)
    }
}
