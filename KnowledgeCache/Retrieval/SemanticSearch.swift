//
//  SemanticSearch.swift
//  KnowledgeCache
//
//  Embed query; dot product over chunks (L2-normalized); top-k. ReindexRequired if dim mismatch.
//

import Foundation

final class SemanticSearch: @unchecked Sendable {
    private static let perSourceChunkLimit = 3

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
        let queryTokens = tokenSet(query)
        let queryNormalized = normalizedAlnum(query)
        let queryTrigrams = trigramSet(queryNormalized)
        let intent = queryIntent(query)

        let firstDim = chunks.first?.embeddingDim ?? 0
        if firstDim != queryDim {
            return .reindexRequired
        }
        if chunks.contains(where: { $0.embeddingDim != queryDim }) {
            return .reindexRequired
        }

        let lexicalRanks = (try? store.searchChunksFTS(query: query, limit: max(40, topK * 8))) ?? []
        var lexicalScoreByChunkId: [String: Float] = [:]
        for (idx, hit) in lexicalRanks.enumerated() {
            // FTS bm25 rank is lower-is-better; convert to bounded score and keep an order bonus.
            let bounded = Float(1.0 / (1.0 + max(0.0, hit.rank)))
            let orderBonus = max(0, lexicalRanks.count - idx)
            let orderScore = Float(orderBonus) / Float(max(1, lexicalRanks.count))
            lexicalScoreByChunkId[hit.chunkId] = max(0, min(1, (0.65 * bounded) + (0.35 * orderScore)))
        }

        var scored: [(KnowledgeStore.ChunkRow, Float)] = []
        for row in chunks {
            let vec = blobToFloats(row.embeddingBlob)
            let semantic = dotProduct(queryVec, vec)
            let lexical = lexicalScore(
                queryTokens: queryTokens,
                queryNormalized: queryNormalized,
                queryTrigrams: queryTrigrams,
                text: row.text
            )
            let ftsLexical = lexicalScoreByChunkId[row.id] ?? 0
            let mergedLexical = max(lexical, ftsLexical)
            var score = (0.65 * semantic) + (0.35 * mergedLexical)
            score += intentBoost(intent: intent, text: row.text)

            // Prefer explicit resume-related sources on resume-like queries.
            if queryTokens.contains("resume") {
                let lowered = row.text.lowercased()
                if lowered.contains("resume") || lowered.contains("cv") {
                    score += 0.2
                }
            }
            scored.append((row, score))
        }
        scored.sort { $0.1 > $1.1 }

        // Diversify by source so one long webpage doesn't crowd out PDFs/docs.
        var top: [(KnowledgeStore.ChunkRow, Float)] = []
        var perSourceCount: [String: Int] = [:]
        for item in scored {
            let sourceId = item.0.knowledgeItemId
            let used = perSourceCount[sourceId, default: 0]
            if used >= Self.perSourceChunkLimit { continue }
            top.append(item)
            perSourceCount[sourceId] = used + 1
            if top.count >= topK { break }
        }

        var results: [RetrievalResult] = []
        for (row, score) in top {
            guard let itemId = UUID(uuidString: row.knowledgeItemId),
                  let item = try? store.fetchItem(id: itemId) else { continue }
            let metadataBoost = metadataScore(
                queryTokens: queryTokens,
                queryNormalized: queryNormalized,
                queryTrigrams: queryTrigrams,
                title: item.title,
                sourceDisplay: item.sourceDisplay,
                intent: intent
            )
            let finalScore = score + metadataBoost
            results.append(RetrievalResult(
                chunkText: row.text,
                score: finalScore,
                knowledgeItemId: itemId,
                title: item.title,
                url: item.url,
                sourceDisplay: item.sourceDisplay
            ))
        }
        results.sort { $0.score > $1.score }
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

    private func lexicalScore(
        queryTokens: Set<String>,
        queryNormalized: String,
        queryTrigrams: Set<String>,
        text: String
    ) -> Float {
        guard !queryTokens.isEmpty || !queryTrigrams.isEmpty else { return 0 }
        let textTokens = tokenSet(text)
        let overlap = queryTokens.isEmpty ? 0 : queryTokens.intersection(textTokens).count
        let tokenOverlap = queryTokens.isEmpty ? 0 : (Float(overlap) / Float(queryTokens.count))

        let textNormalized = normalizedAlnum(String(text.prefix(2000)))
        let textTrigrams = trigramSet(textNormalized)
        let trigram = trigramJaccard(queryTrigrams, textTrigrams)

        // Detect exact phrase even when spacing/punctuation differs (e.g. "dhanushkumar" vs "dhanush kumar").
        let phraseBoost: Float = (!queryNormalized.isEmpty && textNormalized.contains(queryNormalized)) ? 0.2 : 0
        return min(1.0, (0.65 * tokenOverlap) + (0.35 * trigram) + phraseBoost)
    }

    private func metadataScore(
        queryTokens: Set<String>,
        queryNormalized: String,
        queryTrigrams: Set<String>,
        title: String,
        sourceDisplay: String,
        intent: QueryIntent
    ) -> Float {
        let metadata = title + " " + sourceDisplay
        let metadataTokens = tokenSet(metadata)
        let tokenOverlap: Float
        if queryTokens.isEmpty || metadataTokens.isEmpty {
            tokenOverlap = 0
        } else {
            tokenOverlap = Float(queryTokens.intersection(metadataTokens).count) / Float(queryTokens.count)
        }

        let metadataNormalized = normalizedAlnum(metadata)
        let titleNormalized = normalizedAlnum(title)
        let sourceNormalized = normalizedAlnum(sourceDisplay)
        let metadataTrigrams = trigramSet(metadataNormalized)
        let trigram = trigramJaccard(queryTrigrams, metadataTrigrams)
        let phraseBoost: Float = (!queryNormalized.isEmpty && metadataNormalized.contains(queryNormalized)) ? 0.15 : 0

        var score = (0.22 * tokenOverlap) + (0.12 * trigram) + phraseBoost
        if !queryNormalized.isEmpty {
            if titleNormalized.contains(queryNormalized) {
                score += 0.45
            }
            if sourceNormalized.contains(queryNormalized) {
                score += 0.25
            }
        }
        if !queryTokens.isEmpty {
            let titleTokens = tokenSet(title)
            let sourceTokens = tokenSet(sourceDisplay)
            if queryTokens.isSubset(of: titleTokens) {
                score += 0.22
            } else if queryTokens.isSubset(of: sourceTokens) {
                score += 0.14
            }
        }
        let lower = metadata.lowercased()
        if intent.resumeRelated && (lower.contains("resume") || lower.contains(".pdf") || lower.contains("cv")) {
            score += 0.12
        }
        if intent.contactRelated && (lower.contains("contact") || lower.contains("resume")) {
            score += 0.1
        }
        if intent.experienceRelated && (lower.contains("experience") || lower.contains("software engineer")) {
            score += 0.08
        }
        return score
    }

    private func tokenSet(_ text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "do", "does", "did", "has", "have", "had",
            "in", "on", "at", "to", "for", "from", "and", "or", "of", "with", "about", "any",
            "what", "who", "where", "when", "which", "this", "that", "there", "their", "can", "able"
        ]
        let parts = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        let filtered = parts
            .map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
        return Set(filtered)
    }

    private func normalizedAlnum(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private func trigramSet(_ text: String) -> Set<String> {
        guard text.count >= 3 else { return text.isEmpty ? [] : [text] }
        let chars = Array(text)
        var out: Set<String> = []
        if chars.count < 3 { return [text] }
        for i in 0...(chars.count - 3) {
            out.insert(String(chars[i...(i + 2)]))
        }
        return out
    }

    private func trigramJaccard(_ a: Set<String>, _ b: Set<String>) -> Float {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Float(inter) / Float(union)
    }

    private struct QueryIntent {
        let contactRelated: Bool
        let resumeRelated: Bool
        let experienceRelated: Bool
    }

    private func queryIntent(_ query: String) -> QueryIntent {
        let q = query.lowercased()
        let contact = q.contains("contact") || q.contains("email") || q.contains("phone") || q.contains("linkedin")
        let resume = q.contains("resume") || q.contains("cv")
        let experience = q.contains("experience") || q.contains("sde") || q.contains("software engineer")
        return QueryIntent(contactRelated: contact, resumeRelated: resume, experienceRelated: experience)
    }

    private func intentBoost(intent: QueryIntent, text: String) -> Float {
        let lower = text.lowercased()
        var score: Float = 0
        if intent.contactRelated {
            if lower.contains("@") || lower.contains("linkedin") || lower.contains("github") || lower.contains("contact") {
                score += 0.2
            }
        }
        if intent.resumeRelated {
            if lower.contains("resume") || lower.contains("curriculum vitae") || lower.contains("cv") {
                score += 0.16
            }
        }
        if intent.experienceRelated {
            if lower.contains("experience") || lower.contains("software engineer") || lower.contains("intern") || lower.contains("years") {
                score += 0.12
            }
        }
        return score
    }
}
