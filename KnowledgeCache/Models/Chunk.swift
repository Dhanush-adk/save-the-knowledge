//
//  Chunk.swift
//  KnowledgeCache
//
//  One embeddable chunk of text (in-memory view; DB stores embedding_blob).
//

import Foundation

struct Chunk: Identifiable {
    let id: UUID
    let knowledgeItemId: UUID
    let index: Int
    let text: String
    var embedding: [Float]

    init(id: UUID = UUID(), knowledgeItemId: UUID, index: Int, text: String, embedding: [Float]) {
        self.id = id
        self.knowledgeItemId = knowledgeItemId
        self.index = index
        self.text = text
        self.embedding = embedding
    }
}
