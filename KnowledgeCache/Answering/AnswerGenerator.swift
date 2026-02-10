//
//  AnswerGenerator.swift
//  KnowledgeCache
//
//  Answer from retrieved chunks. If Ollama is running locally, uses it for a synthesized
//  answer with same sources; otherwise deterministic paragraph + bullets from chunks.
//

import Foundation

enum AnswerGenerator {
    /// L2-normalized dot-product scores often sit in 0.2–0.5 for good matches; avoid rejecting useful results.
    static let lowConfidenceThreshold: Float = 0.18
    /// Only include chunks from sources whose best score is within this of the top source (avoids mixing e.g. "Dhanush" + TrendRush when only one is relevant).
    static let maxScoreGapFromBest: Float = 0.04
    static let minBullets = 3
    static let maxBullets = 7
    static let maxSentencesPerChunk = 4
    static let minSentenceLength = 20
    static let maxSentenceLength = 400

    static func generate(results: [RetrievalResult], query: String = "") -> AnswerWithSources {
        guard !results.isEmpty else {
            return AnswerWithSources(
                answerText: "No relevant content found in your knowledge base.",
                sources: []
            )
        }
        let bestScore = results.first?.score ?? 0
        let filtered = filterResultsToRelevantSources(results, bestScore: bestScore)
        if bestScore < lowConfidenceThreshold {
            var lines: [String] = ["I'm not very confident this matches your question, but here's what I found in your saved content:"]
            let topResults = filtered.prefix(3)
            let deduped = dedupeResults(Array(topResults))
            for r in deduped {
                let sents = extractInformativeSentences(chunkText: r.chunkText, query: query)
                for sent in sents.prefix(2) {
                    let trimmed = sent.trimmingCharacters(in: .whitespaces)
                    if trimmed.count >= minSentenceLength && trimmed.count <= maxSentenceLength {
                        lines.append("")
                        lines.append("• \(trimmed)")
                        break
                    }
                }
            }
            let sources = Array(Set(filtered.prefix(5).map { $0.sourceRef })).prefix(5)
            if lines.count <= 1 && !sources.isEmpty {
                lines.append("")
                lines.append("Closest sources: " + sources.map { $0.title }.joined(separator: ", "))
            }
            return AnswerWithSources(
                answerText: lines.joined(separator: "\n"),
                sources: Array(sources)
            )
        }

        let deduped = dedupeResults(filtered)
        var sentences: [String] = []
        var seenSourceIds: Set<UUID> = []
        var sourceRefs: [SourceRef] = []

        for r in deduped {
            let sents = extractInformativeSentences(chunkText: r.chunkText, query: query)
            for sent in sents.prefix(maxSentencesPerChunk) {
                let trimmed = sent.trimmingCharacters(in: .whitespaces)
                if trimmed.count >= minSentenceLength && trimmed.count <= maxSentenceLength && !sentences.contains(trimmed) {
                    sentences.append(trimmed)
                }
            }
            if !seenSourceIds.contains(r.sourceRef.id) {
                seenSourceIds.insert(r.sourceRef.id)
                sourceRefs.append(r.sourceRef)
            }
        }

        let paragraphSentenceCount = 8
        let paragraph = sentences.prefix(paragraphSentenceCount).joined(separator: " ")
        let bulletCount = min(maxBullets, max(minBullets, sentences.count))
        let bullets = sentences.dropFirst(paragraphSentenceCount).prefix(bulletCount).map { "• \($0)" }
        var answerText = paragraph
        if !bullets.isEmpty {
            answerText += "\n\n" + bullets.joined(separator: "\n")
        }
        if answerText.trimmingCharacters(in: .whitespaces).isEmpty {
            answerText = "No relevant content found in your knowledge base."
        }
        return AnswerWithSources(answerText: answerText, sources: Array(sourceRefs.prefix(10)))
    }

    /// Uses Ollama if available (user runs Ollama and e.g. "ollama pull llama3.2:latest"). Same sources as deterministic path; returns nil on failure so caller can fall back.
    static func generateWithOllama(
        results: [RetrievalResult],
        query: String,
        model: String = OllamaClient.defaultModel,
        timeout: TimeInterval = OllamaClient.defaultTimeout
    ) async -> AnswerWithSources? {
        guard !results.isEmpty else { return nil }
        let bestScore = results.first?.score ?? 0
        let filtered = filterResultsToRelevantSources(results, bestScore: bestScore)
        let deduped = dedupeResults(filtered)
        var sourceRefs: [SourceRef] = []
        var seenIds: Set<UUID> = []
        var contextParts: [String] = []
        for (idx, r) in deduped.prefix(12).enumerated() {
            let num = idx + 1
            contextParts.append("[\(num)] \(r.sourceDisplay)\n\(r.chunkText)")
            if !seenIds.contains(r.sourceRef.id) {
                seenIds.insert(r.sourceRef.id)
                sourceRefs.append(r.sourceRef)
            }
        }
        let context = contextParts.joined(separator: "\n\n")
        let systemPrompt = "You answer only using the provided context. Be concise. Do not make up information. If the context does not contain the answer, say so briefly."
        let userPrompt = "Context:\n\n\(context)\n\nQuestion: \(query)\n\nAnswer:"
        guard let answerText = await OllamaClient.generate(prompt: userPrompt, system: systemPrompt, model: model, timeout: timeout),
              !answerText.isEmpty else { return nil }
        return AnswerWithSources(
            answerText: answerText,
            sources: Array(sourceRefs.prefix(10))
        )
    }

    /// Keep only chunks from sources (saved items) whose best chunk score is within maxScoreGapFromBest of the top score (so we don't mix e.g. adhanushkumar + trendrush when the query is about Dhanush).
    private static func filterResultsToRelevantSources(_ results: [RetrievalResult], bestScore: Float) -> [RetrievalResult] {
        let minScore = bestScore - maxScoreGapFromBest
        var bestPerItem: [UUID: Float] = [:]
        for r in results {
            bestPerItem[r.knowledgeItemId] = max(bestPerItem[r.knowledgeItemId] ?? 0, r.score)
        }
        let allowedItems = Set(bestPerItem.filter { $0.value >= minScore }.map(\.key))
        return results.filter { allowedItems.contains($0.knowledgeItemId) }
    }

    private static func dedupeResults(_ results: [RetrievalResult]) -> [RetrievalResult] {
        var seen: Set<String> = []
        var out: [RetrievalResult] = []
        for r in results {
            let key = "\(r.knowledgeItemId.uuidString):\(r.chunkText.prefix(100))"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(r)
        }
        return out
    }

    /// Extract 2–4 informative sentences: prefer those with keyword overlap with query; length bounds. Deterministic for same input.
    private static func extractInformativeSentences(chunkText: String, query: String) -> [String] {
        let queryWords = Set(query.lowercased().split(separator: " ").map(String.init))
        let raw = chunkText
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= minSentenceLength && $0.count <= maxSentenceLength }
        if queryWords.isEmpty {
            return Array(raw.prefix(maxSentencesPerChunk))
        }
        let scored = raw.map { sent -> (String, Int) in
            let words = Set(sent.lowercased().split(separator: " ").map(String.init))
            let overlap = words.intersection(queryWords).count
            return (sent, overlap)
        }
        let sorted = scored.sorted { $0.1 > $1.1 }
        return Array(sorted.prefix(maxSentencesPerChunk).map(\.0))
    }
}
