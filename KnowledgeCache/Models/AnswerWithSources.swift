//
//  AnswerWithSources.swift
//  KnowledgeCache
//
//  Answer text plus cited sources (retrieval-only; no external APIs).
//

import Foundation

struct AnswerWithSources {
    var answerText: String
    var sources: [SourceRef]
}
