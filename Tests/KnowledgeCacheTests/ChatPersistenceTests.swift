//
//  ChatPersistenceTests.swift
//  KnowledgeCacheTests
//
//  Persistence coverage for chat threads and messages.
//

import XCTest
@testable import KnowledgeCache

final class ChatPersistenceTests: XCTestCase {
    var db: Database!
    var store: KnowledgeStore!

    override func setUp() {
        super.setUp()
        let path = NSTemporaryDirectory() + "test_chat_\(UUID().uuidString).db"
        db = Database(path: path)
        try? db.open()
        store = KnowledgeStore(db: db)
    }

    override func tearDown() {
        db?.close()
        super.tearDown()
    }

    func testInsertAndFetchChatThreadAndMessages() throws {
        let now = Date()
        let thread = ChatThread(
            title: "I-20 costs",
            createdAt: now,
            updatedAt: now,
            lastMessagePreview: ""
        )
        try store.insertChatThread(thread)

        let user = ChatMessage(
            threadId: thread.id,
            role: .user,
            content: "What is UNCC cost in I-20?",
            createdAt: now
        )
        let assistant = ChatMessage(
            threadId: thread.id,
            role: .assistant,
            content: "Based on I-20, here is the cost breakdown...",
            sources: [
                SourceRef(title: "I-20", url: nil, snippet: "Estimated annual expenses...")
            ],
            suggestions: ["Break down tuition vs living costs", "Show exact source lines used"],
            createdAt: now.addingTimeInterval(1)
        )
        try store.insertChatMessage(user)
        try store.insertChatMessage(assistant)

        let threads = try store.fetchChatThreads()
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads.first?.id, thread.id)
        XCTAssertTrue(threads.first?.lastMessagePreview.contains("Based on I-20") == true)

        let messages = try store.fetchChatMessages(threadId: thread.id)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].sources.count, 1)
        XCTAssertEqual(messages[1].suggestions.count, 2)
    }

    func testDeleteChatThreadCascadesMessages() throws {
        let thread = ChatThread(title: "Delete me")
        try store.insertChatThread(thread)
        try store.insertChatMessage(ChatMessage(threadId: thread.id, role: .user, content: "hello"))

        XCTAssertEqual(try store.fetchChatMessages(threadId: thread.id).count, 1)
        try store.deleteChatThread(threadId: thread.id)
        XCTAssertTrue(try store.fetchChatThreads().isEmpty)
        XCTAssertTrue(try store.fetchChatMessages(threadId: thread.id).isEmpty)
    }

    func testArchiveHidesThreadAndUpdatesAnalytics() throws {
        let thread = ChatThread(title: "Archive me")
        try store.insertChatThread(thread)
        try store.insertChatMessage(ChatMessage(threadId: thread.id, role: .user, content: "question"))
        try store.insertChatMessage(ChatMessage(threadId: thread.id, role: .assistant, content: "answer", sources: [
            SourceRef(title: "Doc", snippet: "snippet")
        ]))

        XCTAssertEqual(try store.fetchChatThreads().count, 1)
        try store.archiveChatThread(threadId: thread.id)
        XCTAssertEqual(try store.fetchChatThreads().count, 0)

        let summary = try store.fetchChatAnalyticsSummary()
        XCTAssertEqual(summary.activeThreads, 0)
        XCTAssertEqual(summary.archivedThreads, 1)
        XCTAssertEqual(summary.totalMessages, 0)
    }
}
