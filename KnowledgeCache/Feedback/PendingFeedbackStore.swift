//
//  PendingFeedbackStore.swift
//  KnowledgeCache
//
//  Stores feedback items to disk when offline; they are sent when the device is back online.
//

import Foundation
import CryptoKit
import Security

struct FeedbackItem: Codable {
    let id: String
    let message: String
    let email: String?
    let type: String
    let appVersion: String
    let osVersion: String
    let timestamp: String
}

final class PendingFeedbackStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.knowledgecache.pendingfeedback", qos: .utility)

    init(appSupportSubpath: String = "KnowledgeCache/pending_feedback.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fullPath = dir.appendingPathComponent(appSupportSubpath)
        self.fileURL = fullPath
        try? FileManager.default.createDirectory(at: fullPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func append(_ item: FeedbackItem) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var list = self.load()
            list.append(item)
            self.save(list)
        }
    }

    func load() -> [FeedbackItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let rawData = try? Data(contentsOf: fileURL) else {
            return []
        }
        if let decrypted = QueueCrypto.decrypt(rawData),
           let list = try? JSONDecoder().decode([FeedbackItem].self, from: decrypted) {
            return list
        }

        // Legacy plaintext migration path: read once, then rewrite encrypted.
        if let legacyList = try? JSONDecoder().decode([FeedbackItem].self, from: rawData) {
            save(legacyList)
            return legacyList
        }
        return []
    }

    func remove(ids: Set<String>) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var list = self.load()
            list.removeAll { ids.contains($0.id) }
            self.save(list)
        }
    }

    func synchronouslyLoad() -> [FeedbackItem] {
        queue.sync { load() }
    }

    func synchronouslyRemove(ids: Set<String>) {
        queue.sync {
            var list = load()
            list.removeAll { ids.contains($0.id) }
            save(list)
        }
    }

    func synchronouslyQueueMetrics(now: Date = Date()) -> (count: Int, oldestPendingAgeSeconds: Int) {
        queue.sync {
            let list = load()
            let oldest = list
                .compactMap { Self.parseTimestamp($0.timestamp) }
                .min()
            let age = oldest.map { max(0, Int(now.timeIntervalSince($0))) } ?? 0
            return (list.count, age)
        }
    }

    private func save(_ list: [FeedbackItem]) {
        guard let plain = try? JSONEncoder().encode(list) else { return }
        guard let encrypted = QueueCrypto.encrypt(plain) else {
            AppLogger.error("PendingFeedbackStore: failed to encrypt queue payload; skip write")
            return
        }
        try? encrypted.write(to: fileURL, options: .atomic)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

private enum QueueCrypto {
    private struct Envelope: Codable {
        let v: Int
        let combined: String
    }

    static func encrypt(_ plain: Data) -> Data? {
        guard let key = QueueCryptoKeychain.loadOrCreateKey() else { return nil }
        guard let sealed = try? AES.GCM.seal(plain, using: key),
              let combined = sealed.combined else { return nil }
        let payload = Envelope(v: 1, combined: combined.base64EncodedString())
        return try? JSONEncoder().encode(payload)
    }

    static func decrypt(_ raw: Data) -> Data? {
        guard let payload = try? JSONDecoder().decode(Envelope.self, from: raw),
              payload.v == 1,
              let combined = Data(base64Encoded: payload.combined),
              let key = QueueCryptoKeychain.loadOrCreateKey(),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let opened = try? AES.GCM.open(box, using: key) else {
            return nil
        }
        return opened
    }
}

private enum QueueCryptoKeychain {
    private static let keyFileSubpath = "KnowledgeCache/pending_feedback.key"
    private static let cacheLock = NSLock()
    private static var cachedKeyData: Data?

    static func loadOrCreateKey() -> SymmetricKey? {
        cacheLock.lock()
        if let cachedKeyData, cachedKeyData.count == 32 {
            cacheLock.unlock()
            return SymmetricKey(data: cachedKeyData)
        }
        cacheLock.unlock()

        if let existing = readKeyData(), existing.count == 32 {
            cacheLock.lock()
            cachedKeyData = existing
            cacheLock.unlock()
            return SymmetricKey(data: existing)
        }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }
        guard storeKeyData(bytes) else { return nil }
        cacheLock.lock()
        cachedKeyData = bytes
        cacheLock.unlock()
        return SymmetricKey(data: bytes)
    }

    private static func readKeyData() -> Data? {
        let fileURL = keyFileURL()
        guard let data = try? Data(contentsOf: fileURL), data.count == 32 else { return nil }
        return data
    }

    private static func storeKeyData(_ data: Data) -> Bool {
        let fileURL = keyFileURL()
        let parent = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    private static func keyFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(keyFileSubpath)
    }
}
