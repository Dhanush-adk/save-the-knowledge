//
//  SourceRef.swift
//  KnowledgeCache
//
//  Reference to a source used in an answer (URL or pasted).
//

import Foundation

struct SourceRef: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var url: String?
    var snippet: String
    /// When set, used to show "Source no longer available" if item was deleted.
    var knowledgeItemId: UUID?

    init(id: UUID = UUID(), title: String, url: String? = nil, snippet: String, knowledgeItemId: UUID? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
        self.knowledgeItemId = knowledgeItemId
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SourceRef, rhs: SourceRef) -> Bool { lhs.id == rhs.id }
}
