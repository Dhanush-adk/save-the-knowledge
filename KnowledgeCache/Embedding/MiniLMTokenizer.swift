//
//  MiniLMTokenizer.swift
//  KnowledgeCache
//
//  WordPiece/BERT-style tokenizer for all-MiniLM-L6-v2.
//  Loads vocab from Bundle "minilm_vocab.txt" (one token per line, index = line number).
//  Deterministic: same input -> same output.
//

import Foundation

final class MiniLMTokenizer {
    static let maxLength = 256

    private let vocab: [String: Int32]
    private let padTokenId: Int32
    private let unkTokenId: Int32
    private let clsTokenId: Int32
    private let sepTokenId: Int32

    /// Load from Bundle. Returns nil if vocab file missing.
    init?(vocabResource: String = "minilm_vocab", extension ext: String = "txt", bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: vocabResource, withExtension: ext),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var map: [String: Int32] = [:]
        for (idx, line) in lines.enumerated() {
            map[String(line)] = Int32(idx)
        }
        self.vocab = map
        self.padTokenId = map["[PAD]"] ?? 0
        self.unkTokenId = map["[UNK]"] ?? 100
        self.clsTokenId = map["[CLS]"] ?? 101
        self.sepTokenId = map["[SEP]"] ?? 102
    }

    /// Encode text to input_ids and attention_mask (fixed length maxLength). Deterministic.
    func encode(_ text: String) -> (inputIds: [Int32], attentionMask: [Int32]) {
        let tokens = tokenize(text)
        var inputIds: [Int32] = [clsTokenId]
        for t in tokens.prefix(Self.maxLength - 2) {
            inputIds.append(vocab[t] ?? unkTokenId)
        }
        inputIds.append(sepTokenId)
        let padCount = Self.maxLength - inputIds.count
        let attentionMask = [Int32](repeating: 1, count: inputIds.count) + [Int32](repeating: 0, count: padCount)
        inputIds.append(contentsOf: [Int32](repeating: padTokenId, count: padCount))
        return (inputIds, attentionMask)
    }

    private func tokenize(_ text: String) -> [String] {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalized.split(separator: " ", omittingEmptySubsequences: true)
        var out: [String] = []
        for word in words {
            out.append(contentsOf: wordPieceTokenize(word: String(word)))
        }
        return out
    }

    private func wordPieceTokenize(word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        var result: [String] = []
        var remaining = word
        while !remaining.isEmpty {
            var found = false
            for len in (1...remaining.count).reversed() {
                let prefix = String(remaining.prefix(len))
                if vocab[prefix] != nil {
                    result.append(prefix)
                    remaining = String(remaining.dropFirst(len))
                    found = true
                    break
                }
            }
            if !found {
                result.append("[UNK]")
                remaining = ""
            }
        }
        return result
    }
}
