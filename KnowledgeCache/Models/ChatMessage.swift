//
//  ChatMessage.swift
//  KnowledgeCache
//
//  One message in a chat conversation.
//

import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var threadId: UUID
    var role: ChatRole
    var content: String
    var sources: [SourceRef]
    var suggestions: [String]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        threadId: UUID,
        role: ChatRole,
        content: String,
        sources: [SourceRef] = [],
        suggestions: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadId = threadId
        self.role = role
        self.content = content
        self.sources = sources
        self.suggestions = suggestions
        self.createdAt = createdAt
    }
}
