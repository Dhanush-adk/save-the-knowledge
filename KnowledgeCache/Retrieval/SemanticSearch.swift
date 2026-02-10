//
//  SemanticSearch.swift
//  KnowledgeCache
//
//  Embed query; dot product over chunks (L2-normalized); top-k. ReindexRequired if dim mismatch.
//

import Foundation

final class SemanticSearch: @unchecked Sendable {
    private let store: KnowledgeStore
    private let embedding: any EmbeddingProviding

    init(store: KnowledgeStore, embedding: any EmbeddingProviding) {
        self.store = store
        self.embedding = embedding
    }

    func search(query: String, topK: Int = 8) -> SearchOutcome {
        guard let queryVec = embedding.embedOne(query) else { return .results([]) }
        let queryDim = embedding.dimension
        let chunks = (try? store.fetchAllChunks()) ?? []
        guard !chunks.isEmpty else { return .results([]) }

        let firstDim = chunks.first?.embeddingDim ?? 0
        if firstDim != queryDim {
            return .reindexRequired
        }
        if chunks.contains(where: { $0.embeddingDim != queryDim }) {
            return .reindexRequired
        }

        var scored: [(KnowledgeStore.ChunkRow, Float)] = []
        for row in chunks {
            let vec = blobToFloats(row.embeddingBlob)
            let score = dotProduct(queryVec, vec)
            scored.append((row, score))
        }
        scored.sort { $0.1 > $1.1 }
        let top = Array(scored.prefix(topK))

        var results: [RetrievalResult] = []
        for (row, score) in top {
            guard let itemId = UUID(uuidString: row.knowledgeItemId),
                  let item = try? store.fetchItem(id: itemId) else { continue }
            results.append(RetrievalResult(
                chunkText: row.text,
                score: score,
                knowledgeItemId: itemId,
                title: item.title,
                url: item.url,
                sourceDisplay: item.sourceDisplay
            ))
        }
        return .results(results)
    }

    private func blobToFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { buf in
            let ptr = buf.bindMemory(to: Float.self)
            return Array(ptr)
        }
    }

    private func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
