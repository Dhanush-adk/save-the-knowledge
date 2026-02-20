//
//  ChatThread.swift
//  KnowledgeCache
//
//  One persistent chat conversation metadata row.
//

import Foundation

struct ChatThread: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var lastMessagePreview: String
    var archivedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastMessagePreview: String = "",
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessagePreview = lastMessagePreview
        self.archivedAt = archivedAt
    }
}
