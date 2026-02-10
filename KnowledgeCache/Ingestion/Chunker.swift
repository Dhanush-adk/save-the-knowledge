//
//  Chunker.swift
//  KnowledgeCache
//
//  Character-based splitting: maxChars 600, overlap 100; prefer sentence/paragraph boundaries.
//

import Foundation

struct Chunker {
    static let defaultMaxChars = 1000
    static let defaultOverlapChars = 120

    /// Returns [(index, text)] for embedding. If maxChunks > 0, returns at most that many chunks.
    static func chunk(text: String, maxChars: Int = defaultMaxChars, overlapChars: Int = defaultOverlapChars, maxChunks: Int = 0) -> [(Int, String)] {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if normalized.isEmpty { return [] }
        if normalized.count <= maxChars { return [(0, normalized)] }

        var chunks: [(Int, String)] = []
        var start = normalized.startIndex
        var index = 0
        while start < normalized.endIndex {
            var end = normalized.index(start, offsetBy: maxChars, limitedBy: normalized.endIndex) ?? normalized.endIndex
            if end < normalized.endIndex {
                // Prefer break at sentence or paragraph
                let segment = String(normalized[start..<end])
                if let lastNewline = segment.lastIndex(of: "\n") {
                    let offset = segment.distance(from: segment.startIndex, to: lastNewline)
                    end = normalized.index(start, offsetBy: offset + 1)
                } else if let lastPeriod = segment.lastIndex(of: ".") {
                    let offset = segment.distance(from: segment.startIndex, to: lastPeriod) + 1
                    end = normalized.index(start, offsetBy: offset)
                }
            }
            let chunkText = String(normalized[start..<end]).trimmingCharacters(in: .whitespaces)
            if !chunkText.isEmpty {
                chunks.append((index, chunkText))
                index += 1
            }
            if end >= normalized.endIndex { break }
            let overlapStart = normalized.index(end, offsetBy: -min(overlapChars, normalized.distance(from: start, to: end)), limitedBy: start) ?? start
            start = overlapStart
            if maxChunks > 0 && chunks.count >= maxChunks { break }
        }
        return chunks
    }
}
