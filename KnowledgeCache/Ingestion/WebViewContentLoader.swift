//
//  WebViewContentLoader.swift
//  KnowledgeCache
//
//  Loads a URL in WKWebView so JavaScript runs, then extracts the full
//  rendered text (title + body). Use this for SPAs like React/Vite sites.
//

import Foundation
import WebKit

@MainActor
final class WebViewContentLoader: NSObject {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<(title: String, body: String), Error>?
    private var timeoutTask: Task<Void, Never>?

    static let waitAfterLoad: TimeInterval = 6.0  // Take time for SPA, animations, and dynamic content
    static let timeout: TimeInterval = 45        // Allow slow pages to load before giving up

    /// Load URL in a headless WebView, wait for render, return visible text.
    func load(url: URL) async throws -> (title: String, body: String) {
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            let config = WKWebViewConfiguration()
            config.processPool = WKProcessPool()
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
            wv.navigationDelegate = self
            self.webView = wv

            let request = URLRequest(url: url)
            wv.load(request)

            self.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                if self.continuation != nil {
                    self.finish(with: .failure(ExtractError.timeout))
                }
            }
        }
    }

    private func finish(with result: Result<(title: String, body: String), Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let cont = continuation else { return }
        continuation = nil
        webView?.stopLoading()
        webView = nil
        switch result {
        case .success(let value): cont.resume(returning: value)
        case .failure(let error): cont.resume(throwing: error)
        }
    }

    /// Removes trailing "|" (typing cursor) from lines so "I'm a Developer|" doesn't get stored or shown mid-animation.
    private static func stripTypingCursor(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line in
                var s = line
                while s.hasSuffix("|") || s.hasSuffix(" |") {
                    if s.hasSuffix(" |") { s = String(s.dropLast(2)) }
                    else { s = String(s.dropLast(1)) }
                }
                return s
            }
            .joined(separator: "\n")
    }

    private func extractContent() {
        guard let wv = webView else { return }
        let script = """
        (function() {
            var title = document.title || '';
            var body = document.body ? document.body.innerText : '';
            return JSON.stringify({ title: title, body: body });
        })();
        """
        wv.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let error = error {
                    self.finish(with: .failure(error))
                    return
                }
                guard let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let title = parsed["title"] as? String,
                      let body = parsed["body"] as? String else {
                    self.finish(with: .failure(ExtractError.invalidEncoding))
                    return
                }
                let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                let withoutTypingCursor = Self.stripTypingCursor(trimmedBody)
                self.finish(with: .success((title: title, body: withoutTypingCursor)))
            }
        }
    }
}

extension WebViewContentLoader: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.waitAfterLoad * 1_000_000_000))
            self.extractContent()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.finish(with: .failure(error))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.finish(with: .failure(error))
        }
    }
}
