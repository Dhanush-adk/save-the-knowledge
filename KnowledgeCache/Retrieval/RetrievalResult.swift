//
//  RetrievalResult.swift
//  KnowledgeCache
//
//  One retrieved chunk with score and source metadata.
//

import Foundation

struct RetrievalResult: Identifiable {
    let id: UUID
    let chunkText: String
    let score: Float
    let knowledgeItemId: UUID
    let title: String
    let url: String?
    let sourceDisplay: String

    init(id: UUID = UUID(), chunkText: String, score: Float, knowledgeItemId: UUID, title: String, url: String?, sourceDisplay: String) {
        self.id = id
        self.chunkText = chunkText
        self.score = score
        self.knowledgeItemId = knowledgeItemId
        self.title = title
        self.url = url
        self.sourceDisplay = sourceDisplay
    }

    var sourceRef: SourceRef {
        SourceRef(title: title, url: url, snippet: String(chunkText.prefix(200)), knowledgeItemId: knowledgeItemId)
    }
}
