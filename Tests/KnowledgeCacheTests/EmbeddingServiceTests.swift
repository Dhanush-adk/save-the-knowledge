//
//  EmbeddingServiceTests.swift
//  KnowledgeCacheTests
//
//  Embedding: availability, determinism, and vector properties.
//

import XCTest
@testable import KnowledgeCache

final class EmbeddingServiceTests: XCTestCase {

    var service: EmbeddingService!

    override func setUp() {
        super.setUp()
        service = EmbeddingService()
    }

    func testDefaultConfiguration() {
        // Core ML + vocab: when both are in bundle, isAvailable is true
        XCTAssertEqual(service.dimension, 384)
        XCTAssertEqual(service.modelId, "minilm-l6-v2-v1")
    }

    func testIsAvailableWhenModelInBundle() {
        guard service.isAvailable else {
            XCTSkip("Embedding model and minilm_vocab.txt not in bundle (run scripts/export_embedding_model.py and add model to target)")
            return
        }
        XCTAssertTrue(service.isAvailable)
    }

    func testEmbedOneDeterminism() {
        guard service.isAvailable else {
            XCTSkip("Embedding not available")
            return
        }
        let a = service.embedOne("hello world")
        let b = service.embedOne("hello world")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(a!, b!, "Same input should produce identical embeddings")
    }

    func testEmbedOneDimension() {
        guard service.isAvailable else {
            XCTSkip("Embedding not available")
            return
        }
        let vec = service.embedOne("test embedding dimension")
        XCTAssertNotNil(vec)
        XCTAssertEqual(vec!.count, EmbeddingService.defaultDimension)
    }

    func testEmbedOneIsNormalized() {
        guard service.isAvailable else {
            XCTSkip("Embedding not available")
            return
        }
        guard let vec = service.embedOne("testing normalization") else {
            XCTFail("embedOne returned nil")
            return
        }
        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
        // L2 norm should be ~1.0 (within floating point tolerance)
        XCTAssertEqual(norm, 1.0, accuracy: 0.01, "Embedding should be L2-normalized")
    }

    func testDifferentInputsDifferentEmbeddings() {
        guard service.isAvailable else {
            XCTSkip("Embedding not available")
            return
        }
        let a = service.embedOne("cats are great pets")
        let b = service.embedOne("quantum physics is complex")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a!, b!, "Different inputs should produce different embeddings")
    }

    func testBatchEmbedding() {
        guard service.isAvailable else {
            XCTSkip("Embedding not available")
            return
        }
        let texts = ["hello", "world", "test"]
        var progressCalls = 0
        let results = service.embed(texts: texts) { _, _ in
            progressCalls += 1
        }
        XCTAssertEqual(results.count, texts.count)
        XCTAssertEqual(progressCalls, texts.count)
    }
}
