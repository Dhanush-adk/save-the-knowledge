//
//  MockEmbeddingService.swift
//  KnowledgeCacheTests
//
//  Returns fixed 384-dim L2-normalized vectors so the full pipeline (save → index → search → answer) runs without the Core ML model.
//

import Foundation
@testable import KnowledgeCache

final class MockEmbeddingService: EmbeddingProviding, @unchecked Sendable {
    static let dim = 384
    private let unitVector: [Float]

    init() {
        let scale = 1.0 / sqrt(Float(Self.dim))
        self.unitVector = (0..<Self.dim).map { _ in scale }
    }

    var isAvailable: Bool { true }
    var dimension: Int { Self.dim }
    var modelId: String { EmbeddingService.defaultModelId }

    func embedOne(_ text: String) -> [Float]? { unitVector }

    func embed(texts: [String], progress: ((Int, Int) -> Void)?) -> [[Float]] {
        progress?(texts.count, texts.count)
        return texts.map { _ in unitVector }
    }
}
