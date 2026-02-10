//
//  IngestionPipeline.swift
//  KnowledgeCache
//
//  Save → Extract → (dedupe by content_hash) → Chunk (limits) → Embed → Store. Off main thread; progress.
//

import Foundation
import CryptoKit

final class IngestionPipeline: @unchecked Sendable {
    static let maxExtractedChars = 500_000
    static let maxChunksPerItem = 500

    private let store: KnowledgeStore
    private let embedding: any EmbeddingProviding
    private let structuredExtractionScriptURL: URL?

    init(store: KnowledgeStore, embedding: any EmbeddingProviding, structuredExtractionScriptURL: URL? = nil) {
        self.store = store
        self.embedding = embedding
        self.structuredExtractionScriptURL = structuredExtractionScriptURL
    }

    /// Ingest from URL. Call from background queue.
    func ingest(url: URL) async throws -> KnowledgeItem {
        let content = try await TextExtractor.extract(from: url)
        return try ingest(title: content.title, rawContent: content.body, url: url.absoluteString, sourceDisplay: url.absoluteString)
    }

    /// Ingest pasted text.
    func ingestPastedText(_ text: String) throws -> KnowledgeItem {
        let content = TextExtractor.fromPastedText(text)
        return try ingest(title: content.title, rawContent: content.body, url: nil, sourceDisplay: "Pasted text")
    }

    private func ingest(title: String, rawContent: String, url: String?, sourceDisplay: String) throws -> KnowledgeItem {
        AppLogger.info("Ingest: title=\(title.prefix(60))... source=\(sourceDisplay.prefix(80))")
        var contentToIngest = rawContent
        if let scriptURL = structuredExtractionScriptURL,
           let structured = StructuredExtractor.run(scriptURL: scriptURL, unstructuredText: rawContent),
           !structured.isEmpty {
            contentToIngest = structured
        }
        let collapsed = collapseConsecutiveDuplicateParagraphs(contentToIngest)
        let normalized = normalizeForHash(collapsed)
        let contentHash = sha256(normalized)

        if let existing = try store.findByContentHash(contentHash) {
            return existing
        }

        var contentToUse = collapsed
        var wasTruncated = false
        if contentToUse.count > Self.maxExtractedChars {
            contentToUse = String(contentToUse.prefix(Self.maxExtractedChars))
            wasTruncated = true
        }
        let finalRawContent = contentToUse

        var chunkPairs = Chunker.chunk(text: contentToUse, maxChunks: Self.maxChunksPerItem).map(\.1)
        if chunkPairs.count > Self.maxChunksPerItem {
            chunkPairs = Array(chunkPairs.prefix(Self.maxChunksPerItem))
            wasTruncated = true
        }
        guard !chunkPairs.isEmpty else {
            AppLogger.warning("Ingest: no content after chunking")
            throw PipelineError.noContent
        }
        guard embedding.isAvailable else {
            AppLogger.error("Ingest: embedding unavailable")
            throw PipelineError.embeddingUnavailable
        }
        let embeddings = embedding.embed(texts: chunkPairs, progress: nil)
        guard embeddings.count == chunkPairs.count else {
            AppLogger.error("Ingest: embedding count mismatch \(embeddings.count)/\(chunkPairs.count)")
            throw PipelineError.embeddingFailed
        }
        let pairs = Array(zip(chunkPairs, embeddings))
        let item = KnowledgeItem(
            title: title,
            url: url,
            rawContent: finalRawContent,
            sourceDisplay: sourceDisplay,
            contentHash: contentHash,
            wasTruncated: wasTruncated
        )
        try store.insert(item: item, chunks: pairs, modelId: embedding.modelId, embeddingDim: embedding.dimension)
        AppLogger.info("Ingest: stored item id=\(item.id) chunks=\(pairs.count)")
        return item
    }

    /// Removes consecutive duplicate paragraphs and repeating line-blocks so repeated DOM blocks (e.g. hero text) don't dominate chunks.
    private func collapseConsecutiveDuplicateParagraphs(_ text: String) -> String {
        let lines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.isEmpty { return text }

        var result: [String] = []
        var i = 0
        let blockSizes = [4, 6, 8, 3, 5, 2]
        while i < lines.count {
            var skipped = false
            for blockSize in blockSizes where blockSize >= 1 && i + blockSize <= lines.count {
                let block = Array(lines[i..<(i + blockSize)])
                let resultSuffix = result.count >= blockSize ? Array(result.suffix(blockSize)) : []
                if resultSuffix == block {
                    i += blockSize
                    skipped = true
                    break
                }
            }
            if !skipped {
                result.append(lines[i])
                i += 1
            }
        }
        return result.joined(separator: "\n\n")
    }

    private func normalizeForHash(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

enum PipelineError: Error, LocalizedError {
    case noContent
    case embeddingUnavailable
    case embeddingFailed

    var errorDescription: String? {
        switch self {
        case .noContent: return "No content could be extracted. The page might be JavaScript-rendered. Try pasting the text content instead."
        case .embeddingUnavailable: return "Embedding model not found. Run scripts/export_embedding_model.py and add EmbeddingModel.mlmodel + minilm_vocab.txt to the app."
        case .embeddingFailed: return "Embedding failed."
        }
    }
}
