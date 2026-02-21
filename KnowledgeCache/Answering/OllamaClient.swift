//
//  OllamaClient.swift
//  KnowledgeCache
//
//  Calls local Ollama (http://localhost:11434) for text generation. No model is shipped;
//  user installs Ollama and runs e.g. "ollama pull llama3.2:1b" once.
//

import Foundation
import AppKit

enum OllamaClient {
    static let defaultBaseURL = URL(string: "http://localhost:11434")!
    /// Model to use for answer generation (smaller default for faster first-time pull).
    static let defaultModel = "llama3.2:1b"
    static let defaultTimeout: TimeInterval = 60
    static let statusCheckTimeout: TimeInterval = 8

    struct Availability {
        let isServerReachable: Bool
        let isModelAvailable: Bool
        let model: String

        var summary: String {
            if !isServerReachable {
                return "Ollama server not reachable. Install/start Ollama first."
            }
            if !isModelAvailable {
                return "Ollama is running, but model '\(model)' is missing. Run: ollama pull \(model)"
            }
            return "Ollama is ready. Model '\(model)' is available."
        }
    }

    /// Generate a single response. Returns nil if Ollama is unavailable or errors.
    static func generate(
        prompt: String,
        system: String? = nil,
        model: String = defaultModel,
        baseURL: URL = defaultBaseURL,
        timeout: TimeInterval = defaultTimeout
    ) async -> String? {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("generate")
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]
        if let system = system, !system.isEmpty {
            body["system"] = system
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = timeout

        let response: String?
        do {
            let (result, urlResponse) = try await URLSession.shared.data(for: request)
            let http = urlResponse as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            if code != 200 {
                let bodyPreview = String(data: result, encoding: .utf8).map { String($0.prefix(300)) } ?? "?"
                AppLogger.warning("Ollama: HTTP \(code) from \(url.absoluteString) — \(bodyPreview)")
                return nil
            }
            let json = try? JSONSerialization.jsonObject(with: result) as? [String: Any]
            response = json?["response"] as? String
        } catch {
            AppLogger.warning("Ollama: request failed — \(error.localizedDescription)")
            response = nil
        }
        return response?.trimmingCharacters(in: .whitespaces).isEmpty == false ? response?.trimmingCharacters(in: .whitespaces) : nil
    }

    /// Streams tokens from Ollama (`stream: true`). Returns the final text when available.
    static func streamGenerate(
        prompt: String,
        system: String? = nil,
        model: String = defaultModel,
        baseURL: URL = defaultBaseURL,
        timeout: TimeInterval = defaultTimeout,
        onToken: @escaping @Sendable (String) async -> Void
    ) async -> (text: String?, streamedAnyToken: Bool, error: String?) {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("generate")
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": true
        ]
        if let system = system, !system.isEmpty {
            body["system"] = system
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return (nil, false, "Invalid request payload")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = timeout

        var fullText = ""
        var streamedAnyToken = false

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                return (nil, false, "HTTP \(code)")
            }

            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard let row = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: row) as? [String: Any] else {
                    continue
                }
                if let error = json["error"] as? String, !error.isEmpty {
                    return (nil, streamedAnyToken, error)
                }
                if let token = json["response"] as? String, !token.isEmpty {
                    streamedAnyToken = true
                    fullText += token
                    await onToken(token)
                }
                if let done = json["done"] as? Bool, done {
                    break
                }
            }

            let normalized = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            return (normalized.isEmpty ? nil : normalized, streamedAnyToken, nil)
        } catch {
            AppLogger.warning("Ollama: stream request failed — \(error.localizedDescription)")
            return (nil, streamedAnyToken, error.localizedDescription)
        }
    }

    /// Checks if Ollama server is reachable and whether the requested model exists locally.
    static func checkAvailability(
        model: String = defaultModel,
        baseURL: URL = defaultBaseURL,
        timeout: TimeInterval = statusCheckTimeout
    ) async -> Availability {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                return Availability(isServerReachable: false, isModelAvailable: false, model: model)
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let models = json["models"] as? [[String: Any]]
            else {
                return Availability(isServerReachable: true, isModelAvailable: false, model: model)
            }
            let names = models.compactMap { $0["name"] as? String }
            let available = names.contains { $0 == model || $0.hasPrefix(model + ":") || model.hasPrefix($0 + ":") }
            return Availability(isServerReachable: true, isModelAvailable: available, model: model)
        } catch {
            return Availability(isServerReachable: false, isModelAvailable: false, model: model)
        }
    }
}

@MainActor
final class OllamaServiceManager: ObservableObject {
    @Published var statusMessage: String = "Not checked."
    @Published var isBusy: Bool = false

    private var managedServeProcess: Process?
    private var activeShellProcess: Process?
    private var cancellationRequested = false
    private var terminateObserver: NSObjectProtocol?

    init() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopManagedServe()
        }
    }

    deinit {
        if let observer = terminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func checkStatus() async -> OllamaClient.Availability {
        let status = await OllamaClient.checkAvailability(model: OllamaClient.defaultModel)
        statusMessage = status.summary
        return status
    }

    func installAndStart(model: String = OllamaClient.defaultModel) async {
        guard !isBusy else { return }
        cancellationRequested = false
        isBusy = true
        defer {
            isBusy = false
            activeShellProcess = nil
        }

        statusMessage = "Checking Ollama installation..."
        if !hasOllamaCommand() {
            statusMessage = "Installing Ollama with Homebrew..."
            let install = await runShell("if command -v brew >/dev/null 2>&1; then brew install ollama; elif [ -x /opt/homebrew/bin/brew ]; then /opt/homebrew/bin/brew install ollama; elif [ -x /usr/local/bin/brew ]; then /usr/local/bin/brew install ollama; else echo '__BREW_NOT_FOUND__'; exit 127; fi")
            if !install.success {
                if cancellationRequested {
                    statusMessage = "Ollama setup cancelled."
                    return
                }
                let output = install.output.lowercased()
                if output.contains("__brew_not_found__") || output.contains("command not found") {
                    statusMessage = "Homebrew is not available from the app environment. Run in Terminal: brew install ollama"
                } else if output.contains("operation not permitted") || output.contains("sandbox") || output.contains("not writable") {
                    statusMessage = "Install blocked by macOS permissions/sandbox. Run manually in Terminal: brew install ollama"
                } else {
                    statusMessage = "Install failed. Run manually in Terminal: brew install ollama"
                }
                return
            }
        }
        if cancellationRequested {
            statusMessage = "Ollama setup cancelled."
            return
        }

        statusMessage = "Pulling model \(model)..."
        let pull = await runShell("ollama pull \(model)")
        if !pull.success {
            if cancellationRequested {
                statusMessage = "Ollama setup cancelled."
                return
            }
            statusMessage = "Model pull failed. Try manually: ollama pull \(model)"
            return
        }
        if cancellationRequested {
            statusMessage = "Ollama setup cancelled."
            return
        }

        statusMessage = "Starting Ollama server..."
        startServeIfNeeded()

        let ready = await waitUntilReady(model: model, timeoutSeconds: 12)
        if ready {
            statusMessage = "Ollama ready. Model '\(model)' available."
        } else {
            statusMessage = "Ollama started, but readiness check timed out. Try 'Check Ollama status'."
        }
    }

    func stopManagedServe() {
        guard let process = managedServeProcess, process.isRunning else { return }
        process.terminate()
        managedServeProcess = nil
    }

    func cancelInstallAndStart() {
        cancellationRequested = true
        if let process = activeShellProcess, process.isRunning {
            process.terminate()
        }
        statusMessage = "Stopping current Ollama operation..."
    }

    private func hasOllamaCommand() -> Bool {
        if runShellSync("command -v ollama >/dev/null 2>&1") == 0 {
            return true
        }
        return FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ollama")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ollama")
    }

    private func startServeIfNeeded() {
        if let process = managedServeProcess, process.isRunning {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "ollama serve"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            managedServeProcess = process
        } catch {
            statusMessage = "Failed to start ollama serve: \(error.localizedDescription)"
        }
    }

    private func waitUntilReady(model: String, timeoutSeconds: Int) async -> Bool {
        for _ in 0..<(timeoutSeconds * 2) {
            let status = await OllamaClient.checkAvailability(model: model)
            if status.isServerReachable, status.isModelAvailable {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func runShell(_ command: String) async -> (success: Bool, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Task { @MainActor [weak self] in
                    if self?.activeShellProcess === proc {
                        self?.activeShellProcess = nil
                    }
                }
                continuation.resume(returning: (proc.terminationStatus == 0, (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)))
            }

            do {
                try process.run()
                activeShellProcess = process
            } catch {
                continuation.resume(returning: (false, error.localizedDescription))
            }
        }
    }

    private func runShellSync(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
