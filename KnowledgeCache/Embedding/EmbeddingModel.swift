//
//  EmbeddingModel.swift
//  KnowledgeCache
//
//  Core ML wrapper for all-MiniLM-L6-v2.
//  Input: input_ids, attention_mask (Int32, shape 1×maxLength)
//  Output: embedding Float32[384]. L2-normalized. Deterministic.
//

import Foundation
import CoreML

enum EmbeddingModelError: Error, LocalizedError {
    case modelNotFound
    case invalidInputOutput(String)
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Embedding model not found. Run scripts/export_embedding_model.py and add EmbeddingModel.mlpackage (or .mlmodel) + minilm_vocab.txt to the app."
        case .invalidInputOutput(let msg):
            return "Embedding model I/O mismatch: \(msg)"
        case .predictionFailed(let msg):
            return "Embedding prediction failed: \(msg)"
        }
    }
}

final class EmbeddingModel {
    private var model: MLModel?
    private let dimension: Int
    private let maxLength: Int

    /// Fallback: locate EmbeddingModel.mlpackage by path in the bundle (directory resources may not resolve via forResource:withExtension:).
    private static func findEmbeddingModelInBundle(_ bundle: Bundle) -> URL? {
        guard let resourcesURL = bundle.resourceURL else { return nil }
        let mlpackage = resourcesURL.appendingPathComponent("EmbeddingModel.mlpackage", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mlpackage.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return mlpackage
    }

    /// Load model from bundle. Throws on missing model or wrong I/O.
    /// Tries compiled .mlmodelc first, then .mlpackage (by name+ext and by full name).
    init(modelName: String = "EmbeddingModel", extension ext: String = "mlmodelc") throws {
        // Prefer .mlmodel (single file with weights); .mlpackage often missing weight.bin
        let url: URL? = Bundle.main.url(forResource: modelName, withExtension: ext)
            ?? Bundle.main.url(forResource: modelName, withExtension: "mlmodel")
            ?? Bundle.main.url(forResource: modelName, withExtension: "mlpackage")
            ?? Bundle.main.url(forResource: "\(modelName).mlpackage", withExtension: nil)
            ?? Self.findEmbeddingModelInBundle(Bundle.main)
        guard let url = url else {
            throw EmbeddingModelError.modelNotFound
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        // Copy from bundle to writable location if needed, then compile (sandbox can block compile from read-only bundle)
        let compileSourceURL: URL
        if url.pathExtension == "mlmodel", url.path.hasPrefix(Bundle.main.bundlePath) {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("KnowledgeCache", isDirectory: true)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            let dest = appDir.appendingPathComponent("EmbeddingModel.mlmodel", isDirectory: false)
            let srcAttrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let destAttrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let srcDate = (srcAttrs?[.modificationDate] as? Date) ?? .distantPast
            let destDate = (destAttrs?[.modificationDate] as? Date) ?? .distantPast
            if !FileManager.default.fileExists(atPath: dest.path) || srcDate > destDate {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
            }
            compileSourceURL = dest
        } else {
            compileSourceURL = url
        }
        let loadURL: URL
        if compileSourceURL.pathExtension == "mlpackage" || compileSourceURL.lastPathComponent.hasSuffix(".mlpackage") {
            loadURL = try MLModel.compileModel(at: compileSourceURL)
        } else if compileSourceURL.pathExtension == "mlmodel" {
            loadURL = try MLModel.compileModel(at: compileSourceURL)
        } else {
            loadURL = compileSourceURL
        }
        self.model = try MLModel(contentsOf: loadURL, configuration: config)
        let desc = model!.modelDescription

        guard let inIds = desc.inputDescriptionsByName["input_ids"],
              let inMask = desc.inputDescriptionsByName["attention_mask"] else {
            throw EmbeddingModelError.invalidInputOutput("expected input_ids and attention_mask")
        }
        let idShape = inIds.multiArrayConstraint?.shape.map { $0.intValue } ?? []
        let maskShape = inMask.multiArrayConstraint?.shape.map { $0.intValue } ?? []
        guard idShape.count >= 2, maskShape.count >= 2 else {
            throw EmbeddingModelError.invalidInputOutput("input_ids and attention_mask must be 2D")
        }
        self.maxLength = idShape.last ?? MiniLMTokenizer.maxLength

        // Accept "embedding" or first output (e.g. var_575 from neuralnetwork export)
        let outDesc = desc.outputDescriptionsByName["embedding"] ?? desc.outputDescriptionsByName.values.first
        guard let outDesc = outDesc else {
            throw EmbeddingModelError.invalidInputOutput("expected one output")
        }
        let outShape = outDesc.multiArrayConstraint?.shape.map { $0.intValue } ?? []
        let dim: Int
        if !outShape.isEmpty, let last = outShape.last, last == 384 {
            dim = 384
        } else if outShape.count == 2 {
            dim = outShape.last ?? 384
        } else if outShape.count == 1 {
            dim = outShape[0]
        } else if outShape.isEmpty {
            dim = 384
        } else {
            AppLogger.warning("EmbeddingModel: unexpected output shape \(outShape), assuming 384")
            dim = 384
        }
        self.dimension = dim
        guard dimension == 384 else {
            throw EmbeddingModelError.invalidInputOutput("embedding dimension must be 384 (got \(dim))")
        }
    }

    var embeddingDimension: Int { dimension }
    var sequenceLength: Int { maxLength }

    /// Embed from token IDs (length must be maxLength). Returns L2-normalized vector. Deterministic.
    func embed(inputIds: [Int32], attentionMask: [Int32]) throws -> [Float] {
        guard let model = model else { throw EmbeddingModelError.modelNotFound }
        let len = min(inputIds.count, maxLength)
        let idsArray = try MLMultiArray(shape: [1, NSNumber(value: maxLength)], dataType: .int32)
        let maskArray = try MLMultiArray(shape: [1, NSNumber(value: maxLength)], dataType: .int32)
        for i in 0..<maxLength {
            idsArray[[0, i] as [NSNumber]] = NSNumber(value: i < len ? inputIds[i] : 0)
            maskArray[[0, i] as [NSNumber]] = NSNumber(value: i < len ? attentionMask[i] : 0)
        }
        let inputs: [String: Any] = [
            "input_ids": idsArray,
            "attention_mask": maskArray,
        ]
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: inputs),
              let output = try? model.prediction(from: provider) else {
            throw EmbeddingModelError.predictionFailed("model.prediction failed")
        }
        let embedding: MLMultiArray
        if let emb = output.featureValue(for: "embedding")?.multiArrayValue {
            embedding = emb
        } else if let first = output.featureNames.first, let emb = output.featureValue(for: first)?.multiArrayValue {
            embedding = emb
        } else {
            throw EmbeddingModelError.predictionFailed("no embedding output")
        }
        var vec = [Float](repeating: 0, count: embedding.count)
        for i in 0..<embedding.count {
            vec[i] = embedding[i].floatValue
        }
        return Self.l2Normalize(vec)
    }

    static func l2Normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-10 else { return v }
        return v.map { $0 / norm }
    }
}
