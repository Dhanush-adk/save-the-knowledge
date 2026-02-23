//
//  PendingIssueStore.swift
//  KnowledgeCache
//
//  Persists issue events locally when offline, then replays to feedback-server.
//

import Foundation

struct PendingIssueItem: Codable, Sendable {
    let id: String
    let category: String
    let severity: String
    let message: String
    let details: String?
    let appVersion: String
    let osVersion: String
    let installId: String
    let sessionId: String
    let timestamp: String
    var attemptCount: Int
    var lastError: String?
}

final class PendingIssueStore {
    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.knowledgecache.pendingissues", qos: .utility)

    init(filename: String = "pending_issues.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KnowledgeCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent(filename)
    }

    func append(_ item: PendingIssueItem) {
        ioQueue.sync {
            var all = loadUnsafe()
            all.append(item)
            saveUnsafe(all)
        }
    }

    func synchronouslyLoad() -> [PendingIssueItem] {
        ioQueue.sync { loadUnsafe() }
    }

    func synchronouslyRemove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        ioQueue.sync {
            var all = loadUnsafe()
            all.removeAll { ids.contains($0.id) }
            saveUnsafe(all)
        }
    }

    func synchronouslyMarkFailure(id: String, error: String) {
        ioQueue.sync {
            var all = loadUnsafe()
            guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
            all[idx].attemptCount += 1
            all[idx].lastError = error
            saveUnsafe(all)
        }
    }

    private func loadUnsafe() -> [PendingIssueItem] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        if let decrypted = QueueCrypto.decrypt(data),
           let decoded = try? JSONDecoder().decode([PendingIssueItem].self, from: decrypted) {
            return decoded
        }

        // Legacy plaintext migration path: read once, then rewrite encrypted.
        if let legacy = try? JSONDecoder().decode([PendingIssueItem].self, from: data) {
            saveUnsafe(legacy)
            return legacy
        }
        return []
    }

    private func saveUnsafe(_ items: [PendingIssueItem]) {
        guard let plain = try? JSONEncoder().encode(items) else { return }
        guard let encrypted = QueueCrypto.encrypt(plain) else {
            AppLogger.error("PendingIssueStore: failed to encrypt queue payload; skip write")
            return
        }
        try? encrypted.write(to: fileURL, options: .atomic)
    }
}
