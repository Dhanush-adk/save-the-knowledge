//
//  ReindexController.swift
//  KnowledgeCache
//
//  Re-embed all chunks with current model. Run on background; report progress.
//

import Foundation

final class ReindexController: @unchecked Sendable {
    private let store: KnowledgeStore
    private let embedding: any EmbeddingProviding

    init(store: KnowledgeStore, embedding: any EmbeddingProviding) {
        self.store = store
        self.embedding = embedding
    }

    /// Re-index all chunks. Progress: (current chunk index, total chunks). Throws on failure.
    func reindexAll(progress: ((Int, Int) -> Void)? = nil) throws {
        let items = try store.fetchAllItems()
        var totalDone = 0
        var totalChunks = 0
        for item in items {
            let chunks = try store.fetchChunksForItem(knowledgeItemId: item.id)
            totalChunks += chunks.count
        }
        for item in items {
            let chunks = try store.fetchChunksForItem(knowledgeItemId: item.id)
            let texts = chunks.map(\.text)
            let embeddings = embedding.embed(texts: texts) { cur, _ in
                progress?(totalDone + cur, totalChunks)
            }
            guard embeddings.count == chunks.count else { throw StoreError.insertFailed }
            for (i, chunk) in chunks.enumerated() {
                let blob = floatsToBlob(embeddings[i])
                try store.updateChunkEmbedding(chunkId: chunk.id, embeddingBlob: blob, modelId: embedding.modelId, embeddingDim: embedding.dimension)
                totalDone += 1
            }
        }
    }

    private func floatsToBlob(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
