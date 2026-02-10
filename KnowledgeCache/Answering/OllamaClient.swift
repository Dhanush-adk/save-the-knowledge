//
//  OllamaClient.swift
//  KnowledgeCache
//
//  Calls local Ollama (http://localhost:11434) for text generation. No model is shipped;
//  user installs Ollama and runs e.g. "ollama pull llama3.2:latest" once.
//

import Foundation

enum OllamaClient {
    static let defaultBaseURL = URL(string: "http://localhost:11434")!
    /// Model to use for answer generation (e.g. llama3.2:latest; user must have pulled it).
    static let defaultModel = "llama3.2:latest"
    static let defaultTimeout: TimeInterval = 60

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
}
