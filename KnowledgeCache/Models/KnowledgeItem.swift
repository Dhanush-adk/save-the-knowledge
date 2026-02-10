//
//  KnowledgeItem.swift
//  KnowledgeCache
//
//  Core data model: one saved item (URL or pasted text).
//

import Foundation

struct KnowledgeItem: Identifiable, Codable {
    let id: UUID
    var title: String
    var url: String?
    var rawContent: String
    var createdAt: Date
    var sourceDisplay: String
    var contentHash: String?
    var wasTruncated: Bool

    init(
        id: UUID = UUID(),
        title: String,
        url: String? = nil,
        rawContent: String,
        createdAt: Date = Date(),
        sourceDisplay: String,
        contentHash: String? = nil,
        wasTruncated: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.rawContent = rawContent
        self.createdAt = createdAt
        self.sourceDisplay = sourceDisplay
        self.contentHash = contentHash
        self.wasTruncated = wasTruncated
    }
}
