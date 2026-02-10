//
//  TextExtractor.swift
//  KnowledgeCache
//
//  URL -> fetch HTML -> reader-style extract; paste -> trim/normalize.
//  Handles both static HTML pages and JS-rendered SPAs (via meta tag fallback).
//

import Foundation

struct ExtractedContent {
    let title: String
    let body: String
}

final class TextExtractor {

    /// Extract from URL. Uses WKWebView so JavaScript-rendered content (SPAs) is fully captured.
    static func extract(from url: URL) async throws -> ExtractedContent {
        let (title, body): (String, String) = try await Task { @MainActor in
            let loader = WebViewContentLoader()
            return try await loader.load(url: url)
        }.value

        let finalTitle = title.isEmpty ? "Untitled" : title
        let finalBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalBody.isEmpty {
            throw ExtractError.emptyContent
        }
        return ExtractedContent(title: finalTitle, body: finalBody)
    }

    /// Extract title and main body from HTML (simple heuristic; no JS).
    static func extractFromHTML(_ html: String, baseURL: String = "") -> ExtractedContent {
        let title = Self.extractTitle(from: html)
        var body = Self.extractBody(from: html)

        // If body extraction produced very little text, try meta descriptions as fallback.
        // This handles JavaScript-rendered single-page apps where <body> is mostly empty.
        if body.trimmingCharacters(in: .whitespacesAndNewlines).count < 50 {
            let metaContent = Self.extractMetaDescriptions(from: html)
            if !metaContent.isEmpty {
                let metaBody = metaContent.joined(separator: "\n\n")
                if metaBody.count > body.count {
                    body = metaBody
                }
            }
        }

        // If still empty after fallback, use the raw visible text from the entire HTML
        if body.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 {
            body = Self.extractAllVisibleText(from: html)
        }

        return ExtractedContent(title: title.isEmpty ? "Untitled" : title, body: body)
    }

    /// For pasted text: one item, title = first line or "Pasted text".
    static func fromPastedText(_ text: String) -> ExtractedContent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ExtractedContent(title: "Pasted text", body: "")
        }
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let body = lines.joined(separator: "\n\n")
        let firstLine = lines.first ?? ""
        let title = firstLine.isEmpty ? "Pasted text" : String(firstLine.prefix(200))
        return ExtractedContent(title: title, body: body)
    }

    // MARK: - Private

    private static func extractTitle(from html: String) -> String {
        // Try <title> tag first
        let lower = html.lowercased()
        if let openStart = lower.range(of: "<title"),
           let openEnd = lower.range(of: ">", range: openStart.upperBound..<lower.endIndex),
           let closeStart = lower.range(of: "</title>", range: openEnd.upperBound..<lower.endIndex) {
            let titleContent = String(html[openEnd.upperBound..<closeStart.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .decodeHTMLEntities()
            if !titleContent.isEmpty {
                return String(titleContent.prefix(500))
            }
        }

        // Fallback to og:title
        if let ogTitle = extractMetaContent(from: html, property: "og:title") {
            return ogTitle
        }

        return "Untitled"
    }

    private static func extractBody(from html: String) -> String {
        var text = html

        // Remove script and style blocks (these never contain readable content)
        text = removeBlocks(text, open: "<script", close: "</script>")
        text = removeBlocks(text, open: "<style", close: "</style>")
        text = removeBlocks(text, open: "<noscript", close: "</noscript>")
        text = removeBlocks(text, open: "<!--", close: "-->")

        // Try to extract <body> content
        let lower = text.lowercased()
        if let bodyStart = lower.range(of: "<body"),
           let bodyOpenEnd = lower.range(of: ">", range: bodyStart.upperBound..<lower.endIndex) {
            if let bodyClose = lower.range(of: "</body>", range: bodyOpenEnd.upperBound..<lower.endIndex) {
                text = String(text[bodyOpenEnd.upperBound..<bodyClose.lowerBound])
            } else {
                text = String(text[bodyOpenEnd.upperBound...])
            }
        }

        // Try to find main content areas first (article, main, section)
        let mainContent = extractMainContent(from: text)
        if !mainContent.isEmpty && mainContent.count > 50 {
            return mainContent
        }

        // Strip all remaining HTML tags
        text = stripAllTags(text)

        // Clean up whitespace
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n\n")
    }

    /// Try to extract content from <article>, <main>, or major <section> blocks
    private static func extractMainContent(from html: String) -> String {
        let lower = html.lowercased()

        // Try <article> first, then <main>, then largest <section>
        for tag in ["article", "main"] {
            if let openStart = lower.range(of: "<\(tag)"),
               let openEnd = lower.range(of: ">", range: openStart.upperBound..<lower.endIndex),
               let closeStart = lower.range(of: "</\(tag)>", range: openEnd.upperBound..<lower.endIndex) {
                let content = String(html[openEnd.upperBound..<closeStart.lowerBound])
                let cleaned = stripAllTags(removeBlocks(content, open: "<script", close: "</script>"))
                let lines = cleaned
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let result = lines.joined(separator: "\n\n")
                if result.count > 50 {
                    return result
                }
            }
        }
        return ""
    }

    /// Extract meta description, og:description, twitter:description
    private static func extractMetaDescriptions(from html: String) -> [String] {
        var descriptions: [String] = []

        // Standard meta description
        if let desc = extractMetaContent(from: html, name: "description") {
            descriptions.append(desc)
        }

        // Open Graph description
        if let ogDesc = extractMetaContent(from: html, property: "og:description") {
            if !descriptions.contains(ogDesc) {
                descriptions.append(ogDesc)
            }
        }

        // Twitter description
        if let twDesc = extractMetaContent(from: html, name: "twitter:description") {
            if !descriptions.contains(twDesc) {
                descriptions.append(twDesc)
            }
        }

        // Author
        if let author = extractMetaContent(from: html, name: "author") {
            descriptions.append("Author: \(author)")
        }

        // Keywords
        if let keywords = extractMetaContent(from: html, name: "keywords") {
            descriptions.append("Keywords: \(keywords)")
        }

        return descriptions
    }

    /// Extract content attribute from a <meta> tag by name or property
    private static func extractMetaContent(from html: String, name: String? = nil, property: String? = nil) -> String? {
        let lower = html.lowercased()
        var searchStart = lower.startIndex

        while let metaStart = lower.range(of: "<meta", range: searchStart..<lower.endIndex) {
            // Find the end of this meta tag
            guard let metaEnd = lower.range(of: ">", range: metaStart.upperBound..<lower.endIndex) else { break }
            let tagRange = metaStart.lowerBound..<metaEnd.upperBound
            let tagLower = String(lower[tagRange])
            let tagOriginal = String(html[tagRange])

            var matches = false
            if let name = name {
                matches = tagLower.contains("name=\"\(name)\"") || tagLower.contains("name='\(name)'")
            }
            if let property = property {
                matches = matches || tagLower.contains("property=\"\(property)\"") || tagLower.contains("property='\(property)'")
            }

            if matches {
                // Extract content="..."
                if let contentStart = tagOriginal.range(of: "content=\""),
                   let contentEnd = tagOriginal.range(of: "\"", range: contentStart.upperBound..<tagOriginal.endIndex) {
                    let content = String(tagOriginal[contentStart.upperBound..<contentEnd.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .decodeHTMLEntities()
                    if !content.isEmpty {
                        return content
                    }
                }
                // Try content='...'
                if let contentStart = tagOriginal.range(of: "content='"),
                   let contentEnd = tagOriginal.range(of: "'", range: contentStart.upperBound..<tagOriginal.endIndex) {
                    let content = String(tagOriginal[contentStart.upperBound..<contentEnd.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .decodeHTMLEntities()
                    if !content.isEmpty {
                        return content
                    }
                }
            }

            searchStart = metaEnd.upperBound
        }
        return nil
    }

    /// Last resort: strip ALL tags from entire HTML and return visible text
    private static func extractAllVisibleText(from html: String) -> String {
        var text = removeBlocks(html, open: "<script", close: "</script>")
        text = removeBlocks(text, open: "<style", close: "</style>")
        text = removeBlocks(text, open: "<!--", close: "-->")
        text = stripAllTags(text)
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count > 2 }
        return lines.joined(separator: "\n\n")
    }

    /// Remove HTML blocks like <script>...</script>
    private static func removeBlocks(_ html: String, open: String, close: String) -> String {
        var result = html
        let lower = result.lowercased()
        var searchStart = lower.startIndex

        while let openRange = lower.range(of: open, range: searchStart..<lower.endIndex) {
            if let closeRange = lower.range(of: close, range: openRange.upperBound..<lower.endIndex) {
                let origStart = result.index(result.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: openRange.lowerBound))
                let origEnd = result.index(result.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: closeRange.upperBound))
                result.replaceSubrange(origStart..<origEnd, with: " ")
                return removeBlocks(result, open: open, close: close)
            } else {
                break
            }
        }
        return result
    }

    private static func stripAllTags(_ html: String) -> String {
        var result = html
        while let start = result.range(of: "<"),
              let end = result.range(of: ">", range: start.upperBound..<result.endIndex) {
            result.replaceSubrange(start.lowerBound...end.lowerBound, with: " ")
        }
        return result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .decodeHTMLEntities()
    }
}

private extension String {
    func decodeHTMLEntities() -> String {
        self
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&#34;", with: "\"")
    }
}

enum ExtractError: Error, LocalizedError {
    case invalidEncoding
    case emptyContent
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "Could not read the page content (invalid encoding)."
        case .emptyContent: return "The page appears to be JavaScript-rendered. Try pasting the content instead."
        case .timeout: return "The page took too long to load."
        }
    }
}
