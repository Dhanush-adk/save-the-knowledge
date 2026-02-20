//
//  AnswerGenerator.swift
//  KnowledgeCache
//
//  Answer from retrieved chunks. If Ollama is running locally, uses it for a synthesized
//  answer with same sources; otherwise deterministic paragraph + bullets from chunks.
//

import Foundation

enum AnswerGenerator {
    struct OllamaPrompt {
        let systemPrompt: String
        let userPrompt: String
        let sources: [SourceRef]
    }
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
        if let targeted = generateTargetedProfileAnswer(results: results, query: query) {
            return targeted
        }
        let filtered = filterResultsToRelevantSources(results, bestScore: bestScore, query: query)
        if bestScore < lowConfidenceThreshold {
            var lines: [String] = ["I'm not very confident this matches your question, but here's what I found in your saved content:"]
            let topResults = filtered.prefix(3)
            let deduped = dedupeResults(Array(topResults))
            for r in deduped {
                let sents = extractInformativeSentences(chunkText: r.chunkText, query: query)
            for sent in sents.prefix(2) {
                let trimmed = normalizeSentence(sent)
                if trimmed.count >= minSentenceLength && trimmed.count <= maxSentenceLength && isLikelyReadableSentence(trimmed) {
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
        var candidates: [(sentence: String, score: Int, overlap: Int)] = []
        var seenSourceIds: Set<UUID> = []
        var sourceRefs: [SourceRef] = []

        for (idx, r) in deduped.enumerated() {
            let sents = extractInformativeSentences(chunkText: r.chunkText, query: query)
            for sent in sents.prefix(maxSentencesPerChunk) {
                let normalized = normalizeSentence(sent)
                if normalized.count >= minSentenceLength && normalized.count <= maxSentenceLength && isLikelyReadableSentence(normalized) {
                    let overlap = keywordOverlap(sentence: normalized, query: query)
                    let rankBoost = max(0, 20 - idx)
                    candidates.append((normalized, overlap * 10 + rankBoost, overlap))
                }
            }
            if !seenSourceIds.contains(r.sourceRef.id) {
                seenSourceIds.insert(r.sourceRef.id)
                sourceRefs.append(r.sourceRef)
            }
        }

        let ranked = rankAndDedupeCandidates(candidates, query: query)
        let summaryCount = min(2, ranked.count)
        let summary = ranked.prefix(summaryCount).joined(separator: " ")
        let detailCount = min(maxBullets, max(minBullets, ranked.count))
        let detail = ranked.prefix(detailCount)
        var lines: [String] = []

        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Based on your saved documents, here is a concise answer to \"\(query)\":")
        } else {
            lines.append("Based on your saved documents, here is a concise answer:")
        }
        if !summary.isEmpty {
            lines.append("")
            lines.append(summary)
        }
        if !detail.isEmpty {
            lines.append("")
            lines.append("Key points:")
            for (idx, sentence) in detail.enumerated() {
                lines.append("\(idx + 1). \(sentence)")
            }
        }
        var answerText = lines.joined(separator: "\n")
        if answerText.trimmingCharacters(in: .whitespaces).isEmpty {
            answerText = "No relevant content found in your knowledge base."
        }
        return AnswerWithSources(answerText: answerText, sources: Array(sourceRefs.prefix(10)))
    }

    private static func generateTargetedProfileAnswer(results: [RetrievalResult], query: String) -> AnswerWithSources? {
        let q = query.lowercased()
        guard !q.isEmpty else { return nil }
        let deduped = dedupeResults(results)
        let sourceRefs = Array(Set(deduped.prefix(8).map { $0.sourceRef })).prefix(8)
        let combined = deduped.map(\.chunkText).joined(separator: "\n")

        let asksContact = q.contains("contact") || q.contains("email") || q.contains("phone")
        if asksContact {
            let emails = findMatches(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, in: combined)
            let phones = findMatches(pattern: #"\+?\d[\d\-\(\) ]{8,}\d"#, in: combined)
            let linkedIn = findUrlLikeToken(containing: "linkedin", in: combined)
            let github = findUrlLikeToken(containing: "github", in: combined)
            var lines: [String] = ["From your saved documents, I found these contact details:"]
            if let email = emails.first { lines.append("1. Email: \(email)") }
            if let phone = phones.first { lines.append("2. Phone: \(phone)") }
            if let linkedIn { lines.append("3. LinkedIn: \(linkedIn)") }
            if let github { lines.append("4. GitHub: \(github)") }
            if lines.count > 1 {
                return AnswerWithSources(answerText: lines.joined(separator: "\n"), sources: Array(sourceRefs))
            }
        }

        let asksResume = q.contains("resume")
        if asksResume {
            let hasResumeEvidence = combined.lowercased().contains("resume")
                || deduped.contains { $0.title.lowercased().contains("resume") || $0.sourceDisplay.lowercased().contains("resume") }
            if hasResumeEvidence {
                return AnswerWithSources(
                    answerText: "Yes. Your saved documents include resume content.",
                    sources: Array(sourceRefs)
                )
            }
        }

        let asksSdeExperience = (q.contains("sde") || q.contains("software engineer") || q.contains("software development engineer"))
            && (q.contains("experience") || q.contains("has any"))
        if asksSdeExperience {
            let evidence = extractFirstEvidenceSentence(
                from: deduped.map(\.chunkText),
                keywords: ["software engineer", "years of experience", "experience", "backend systems", "production-grade code"]
            )
            if let evidence {
                let answer = "Yes. Based on your saved documents, there is SDE-relevant experience evidence. \(evidence)"
                return AnswerWithSources(answerText: answer, sources: Array(sourceRefs))
            }
        }

        return nil
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
        let filtered = filterResultsToRelevantSources(results, bestScore: bestScore, query: query)
        let prompt = composePrompt(results: filtered, query: query)
        let systemPrompt = prompt.systemPrompt
        let userPrompt = prompt.userPrompt
        guard let answerText = await OllamaClient.generate(prompt: userPrompt, system: systemPrompt, model: model, timeout: timeout),
              !answerText.isEmpty else { return nil }
        return AnswerWithSources(
            answerText: answerText,
            sources: prompt.sources
        )
    }

    static func composePrompt(results: [RetrievalResult], query: String) -> OllamaPrompt {
        let deduped = dedupeResults(results)
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
        let systemPrompt = """
        You are a grounded assistant for Save the Knowledge.
        Use only the provided context from the user's saved knowledge base.
        Prioritize knowledge-base evidence over assumptions.
        Be concise and accurate. Do not invent facts.
        If the answer is present, clearly indicate it is from the knowledge base.
        If the context does not contain the answer, say that briefly.
        """
        let userPrompt = "Context:\n\n\(context)\n\nQuestion: \(query)\n\nAnswer:"
        return OllamaPrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            sources: Array(sourceRefs.prefix(10))
        )
    }

    /// Keep only chunks from sources (saved items) whose best chunk score is within maxScoreGapFromBest of the top score (so we don't mix e.g. adhanushkumar + trendrush when the query is about Dhanush).
    private static func filterResultsToRelevantSources(_ results: [RetrievalResult], bestScore: Float, query: String) -> [RetrievalResult] {
        let queryNormalized = normalizedAlnum(query)
        let queryTokens = tokenSet(query)
        if !queryNormalized.isEmpty || !queryTokens.isEmpty {
            var metadataMatchedItems: Set<UUID> = []
            for r in results {
                let titleLower = r.title.lowercased()
                let sourceLower = r.sourceDisplay.lowercased()
                let titleNormalized = normalizedAlnum(titleLower)
                let sourceNormalized = normalizedAlnum(sourceLower)
                let titleTokens = tokenSet(titleLower)
                let sourceTokens = tokenSet(sourceLower)
                let phraseMatch = (!queryNormalized.isEmpty) && (titleNormalized.contains(queryNormalized) || sourceNormalized.contains(queryNormalized))
                let tokenMatch = (!queryTokens.isEmpty) && (queryTokens.isSubset(of: titleTokens) || queryTokens.isSubset(of: sourceTokens))
                if phraseMatch || tokenMatch {
                    metadataMatchedItems.insert(r.knowledgeItemId)
                }
            }
            if !metadataMatchedItems.isEmpty {
                return results.filter { metadataMatchedItems.contains($0.knowledgeItemId) }
            }
        }

        let minScore = bestScore - maxScoreGapFromBest
        var bestPerItem: [UUID: Float] = [:]
        for r in results {
            bestPerItem[r.knowledgeItemId] = max(bestPerItem[r.knowledgeItemId] ?? 0, r.score)
        }
        let allowedItems = Set(bestPerItem.filter { $0.value >= minScore }.map(\.key))
        return results.filter { allowedItems.contains($0.knowledgeItemId) }
    }

    private static func normalizedAlnum(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
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
        let queryWords = tokenSet(query)
        let raw = chunkText
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n•"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= minSentenceLength && $0.count <= maxSentenceLength }
        if queryWords.isEmpty {
            return Array(raw.prefix(maxSentencesPerChunk))
        }
        let scored = raw.map { sent -> (String, Int) in
            let overlap = tokenSet(sent).intersection(queryWords).count
            return (sent, overlap)
        }
        let sorted = scored.sorted {
            if $0.1 == $1.1 { return $0.0 < $1.0 }
            return $0.1 > $1.1
        }
        return Array(sorted.prefix(maxSentencesPerChunk).map(\.0))
    }

    private static func rankAndDedupeCandidates(_ candidates: [(sentence: String, score: Int, overlap: Int)], query: String) -> [String] {
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasOverlapCandidate = hasQuery && candidates.contains { $0.overlap > 0 }
        let input = hasOverlapCandidate ? candidates.filter { $0.overlap > 0 } : candidates
        if input.isEmpty { return [] }
        let sorted = input.sorted {
            if $0.score == $1.score { return $0.sentence < $1.sentence }
            return $0.score > $1.score
        }
        var seen: Set<String> = []
        var out: [String] = []
        for c in sorted {
            let key = c.sentence.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(c.sentence)
        }
        return out
    }

    private static func normalizeSentence(_ sentence: String) -> String {
        var text = sentence
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "•", with: " ")
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;-"))
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        if let first = text.first {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }
        if let last = text.last, !".!?".contains(last) {
            text.append(".")
        }
        return text
    }

    private static func isLikelyReadableSentence(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        let blockedPhrases = [
            "name email",
            "project / message",
            "send message",
            "all rights reserved",
            "about projects experience publications resume contact",
            "download resume",
            "view online",
            "get in touch",
            "let's work together",
            "©"
        ]
        if blockedPhrases.contains(where: { lower.contains($0) }) {
            return false
        }
        let words = sentence.split(separator: " ")
        if words.count < 6 || words.count > 40 {
            return false
        }
        if let first = words.first, let second = words.dropFirst().first {
            let firstWord = String(first)
            let secondWord = String(second).lowercased()
            // Reject fragment-like starts such as "AI building ..." that read as broken clauses.
            if firstWord.uppercased() == firstWord && firstWord.count <= 4 && secondWord.hasSuffix("ing") {
                return false
            }
        }
        let mustContainVerb = [
            " is ", " are ", " was ", " were ", " has ", " have ", " had ",
            " works ", " worked ", " working ", " build ", " built ", " building ",
            " develop ", " developed ", " designing ", " includes ", " include "
        ]
        if !mustContainVerb.contains(where: { lower.contains($0) }) {
            return false
        }
        let letters = sentence.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = sentence.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        if letters < 20 {
            return false
        }
        if digits > letters / 2 {
            return false
        }
        return true
    }

    private static func keywordOverlap(sentence: String, query: String) -> Int {
        let left = tokenSet(sentence)
        let right = tokenSet(query)
        if right.isEmpty { return 0 }
        return left.intersection(right).count
    }

    private static func tokenSet(_ input: String) -> Set<String> {
        let cleaned = input.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        let text = String(cleaned)
        return Set(text.split(separator: " ").map(String.init))
    }

    private static func extractFirstEvidenceSentence(from chunks: [String], keywords: [String]) -> String? {
        for chunk in chunks {
            let sentences = chunk
                .replacingOccurrences(of: "\n", with: " ")
                .components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= minSentenceLength && $0.count <= maxSentenceLength }
            for sentence in sentences {
                let lower = sentence.lowercased()
                if keywords.contains(where: { lower.contains($0) }) {
                    return normalizeSentence(sentence)
                }
            }
        }
        return nil
    }

    private static func findMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 0 else { return nil }
            return ns.substring(with: match.range(at: 0))
        }
    }

    private static func findUrlLikeToken(containing needle: String, in text: String) -> String? {
        let tokens = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .map(String.init)
        return tokens.first { token in
            let t = token.lowercased()
            return t.contains(needle) && (t.contains("http") || t.contains(".com") || t.contains("www"))
        }
    }
}
