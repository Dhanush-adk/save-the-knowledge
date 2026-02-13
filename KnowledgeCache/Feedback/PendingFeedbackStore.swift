//
//  PendingFeedbackStore.swift
//  KnowledgeCache
//
//  Stores feedback items to disk when offline; they are sent when the device is back online.
//

import Foundation

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
              let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([FeedbackItem].self, from: data) else {
            return []
        }
        return list
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
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL)
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
