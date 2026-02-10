//
//  EmbeddingService.swift
//  KnowledgeCache
//
//  Tokenize in Swift (WordPiece) -> Core ML (input_ids, attention_mask) -> embedding Float32[384].
//  L2-normalized. Deterministic. No runtime downloads. Model bundled in app.
//

import Foundation

final class EmbeddingService: EmbeddingProviding, @unchecked Sendable {
    static let defaultModelId = "minilm-l6-v2-v1"
    static let defaultDimension = 384

    private let tokenizer: MiniLMTokenizer?
    private let model: EmbeddingModel?
    private let batchSize: Int

    init(vocabResource: String = "minilm_vocab", modelName: String = "EmbeddingModel", batchSize: Int = 5) {
        self.tokenizer = MiniLMTokenizer(vocabResource: vocabResource, extension: "txt", bundle: .main)
        if tokenizer == nil {
            AppLogger.error("EmbeddingService: MiniLMTokenizer failed to load (vocab: \(vocabResource).txt)")
        }
        do {
            self.model = try EmbeddingModel(modelName: modelName)
        } catch {
            AppLogger.error("EmbeddingService: EmbeddingModel failed to load: \(error.localizedDescription)")
            self.model = nil
        }
        self.batchSize = batchSize
        AppLogger.info("EmbeddingService: available=\(tokenizer != nil && model != nil)")
    }

    var isAvailable: Bool { tokenizer != nil && model != nil }
    var dimension: Int { model?.embeddingDimension ?? Self.defaultDimension }
    var modelId: String { Self.defaultModelId }

    /// Embed one string. Deterministic. Returns nil if tokenizer or model unavailable.
    func embedOne(_ text: String) -> [Float]? {
        guard let tokenizer = tokenizer, let model = model else { return nil }
        let (ids, mask) = tokenizer.encode(text)
        guard ids.count == MiniLMTokenizer.maxLength else { return nil }
        return try? model.embed(inputIds: ids, attentionMask: mask)
    }

    /// Embed multiple texts. Progress: (current, total). Deterministic.
    func embed(texts: [String], progress: ((Int, Int) -> Void)? = nil) -> [[Float]] {
        guard let tokenizer = tokenizer, let model = model else { return [] }
        var results: [[Float]] = []
        for (i, text) in texts.enumerated() {
            let (ids, mask) = tokenizer.encode(text)
            if ids.count == MiniLMTokenizer.maxLength, let vec = try? model.embed(inputIds: ids, attentionMask: mask) {
                results.append(vec)
            }
            progress?(i + 1, texts.count)
        }
        return results
    }
}
