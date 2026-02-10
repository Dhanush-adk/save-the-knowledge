//
//  QueryHistoryItem.swift
//  KnowledgeCache
//
//  One past ask: question, answer, sources, timestamp.
//

import Foundation

struct QueryHistoryItem: Identifiable, Codable {
    let id: UUID
    var question: String
    var answerText: String
    var sources: [SourceRef]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        question: String,
        answerText: String,
        sources: [SourceRef],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.question = question
        self.answerText = answerText
        self.sources = sources
        self.createdAt = createdAt
    }
}
