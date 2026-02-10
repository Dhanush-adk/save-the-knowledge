//
//  SearchOutcome.swift
//  KnowledgeCache
//
//  Result of semantic search: either results or re-index required (dimension mismatch).
//

import Foundation

enum SearchOutcome {
    case results([RetrievalResult])
    case reindexRequired
}
