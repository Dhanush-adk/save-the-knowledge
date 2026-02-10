//
//  EmbeddingProviding.swift
//  KnowledgeCache
//
//  Protocol for embedding so tests can inject a mock and run the full pipeline without the Core ML model.
//

import Foundation

protocol EmbeddingProviding: AnyObject {
    var isAvailable: Bool { get }
    var dimension: Int { get }
    var modelId: String { get }
    func embedOne(_ text: String) -> [Float]?
    func embed(texts: [String], progress: ((Int, Int) -> Void)?) -> [[Float]]
}
