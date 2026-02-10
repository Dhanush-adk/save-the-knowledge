//
//  AppLogger.swift
//  KnowledgeCache
//
//  Writes logs to Application Support/KnowledgeCache/logs/ so you can
//  inspect them in the next session for debugging.
//

import Foundation

enum LogLevel: String {
    case debug
    case info
    case warning
    case error
}

enum AppLogger {
    private static let queue = DispatchQueue(label: "com.knowledgecache.logger", qos: .utility)
    private static var logFileURL: URL? = {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("KnowledgeCache", isDirectory: true)
        let logsDir = appDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("KnowledgeCache.log", isDirectory: false)
    }()

    /// Directory where logs are stored. Use for "Open Logs" or docs.
    static var logsDirectoryURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("KnowledgeCache/logs", isDirectory: true)
    }

    static func log(_ level: LogLevel, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = formatter.string(from: Date())
        let filename = (file as NSString).lastPathComponent
        let lineStr = "[\(ts)] [\(level.rawValue.uppercased())] \(message) (\(filename):\(line))"
        let fullLine = lineStr + "\n"
        queue.async {
            guard let url = logFileURL else { return }
            if let data = fullLine.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    if let h = try? FileHandle(forWritingTo: url) {
                        h.seekToEndOfFile()
                        h.write(data)
                        try? h.close()
                    }
                } else {
                    try? data.write(to: url)
                }
            }
        }
        #if DEBUG
        print(lineStr)
        #endif
    }

    static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.debug, message, file: file, function: function, line: line)
    }

    static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, message, file: file, function: function, line: line)
    }

    static func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, message, file: file, function: function, line: line)
    }

    static func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, message, file: file, function: function, line: line)
    }
}
