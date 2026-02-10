//
//  StructuredExtractor.swift
//  KnowledgeCache
//
//  Runs the LangExtract Python script to convert unstructured text into
//  structured form (summary, key points, facts). Optional pipeline step.
//  Call from a background queue; the script may take up to structuredExtractionTimeoutSeconds.
//

import Foundation

enum StructuredExtractor {
    /// Max time to wait for the LangExtract script (LLM calls can be slow).
    static let structuredExtractionTimeoutSeconds: TimeInterval = 90

    /// Run the LangExtract script with `unstructuredText` on stdin; return stdout on success, nil on failure.
    /// - Parameters:
    ///   - scriptURL: Path to scripts/extract_structured.py (or equivalent).
    ///   - unstructuredText: Raw body text from the page.
    ///   - pythonCommand: Command to run Python (default: "python3"; use full path if needed).
    /// - Returns: Structured text from the script, or nil if script missing/failed/timed out.
    static func run(
        scriptURL: URL,
        unstructuredText: String,
        pythonCommand: String = "python3"
    ) -> String? {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [pythonCommand, scriptURL.path]
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            if let data = unstructuredText.data(using: .utf8) {
                (process.standardInput as? Pipe)?.fileHandleForWriting.write(data)
                (process.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
            }
            let finished = process.waitUntilExit(orTimeout: Self.structuredExtractionTimeoutSeconds)
            guard finished, process.terminationStatus == 0 else { return nil }
            let outData = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

extension Process {
    /// Wait until the process exits or the timeout elapses. Returns true if process exited normally, false if timed out (process is terminated).
    fileprivate func waitUntilExit(orTimeout seconds: TimeInterval) -> Bool {
        let start = Date()
        while isRunning && Date().timeIntervalSince(start) < seconds {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if isRunning {
            terminate()
            return false
        }
        return true
    }
}
