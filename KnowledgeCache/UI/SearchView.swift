//
//  SearchView.swift
//  KnowledgeCache
//
//  Ask questions against your local knowledge base.
//

import SwiftUI

struct SearchView: View {
    @ObservedObject var app: AppState
    @State private var query = ""
    @State private var showReindexRequired = false

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.title3)

                TextField("Ask your knowledge base...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { runSearch() }

                if app.searchInProgress {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 20, height: 20)
                } else {
                    Button(action: runSearch) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Results area
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let err = app.searchError {
                        alertBanner(err, color: .red)
                    }

                    if showReindexRequired {
                        alertBanner("Embedding dimension changed. Go to Library > Re-index all to fix.", color: .orange)
                    }

                    if app.savedItems.isEmpty && !app.searchInProgress {
                        emptyState
                    } else if let answer = app.lastAnswer {
                        answerView(answer)
                    } else if !app.searchInProgress && app.lastAnswer == nil && !app.savedItems.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "text.magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)
                            Text("Ask a question to search your saved knowledge")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 80)
                    }
                }
                .padding(24)
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Your knowledge base is empty")
                .font(.title3)
                .fontWeight(.medium)
            Text("Save a URL or paste text to get started")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func answerView(_ answer: AnswerWithSources) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Answer section
            VStack(alignment: .leading, spacing: 8) {
                Label("Answer", systemImage: "lightbulb.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(answer.answerText)
                    .textSelection(.enabled)
                    .font(.body)
                    .lineSpacing(4)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Sources section
            if !answer.sources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sources", systemImage: "doc.text.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    ForEach(answer.sources) { src in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: src.url != nil ? "link" : "doc.text")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 2) {
                                if let urlString = src.url, let url = URL(string: urlString) {
                                    Link(destination: url) {
                                        Text(src.title)
                                            .lineLimit(1)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                    }
                                } else {
                                    Text(src.title)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                }
                                Text(src.snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func alertBanner(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let startedAt = Date()
        app.searchError = nil
        app.lastAnswer = nil
        app.searchInProgress = true
        let search = app.search
        let store = app.store
        Task.detached(priority: .userInitiated) {
            let outcome = search.search(query: q, topK: 8)
            switch outcome {
            case .reindexRequired:
                await MainActor.run {
                    showReindexRequired = true
                    app.lastAnswer = nil
                    app.searchInProgress = false
                    let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    app.trackQuery(question: q, success: false, latencyMs: latencyMs)
                }
            case .results(let results):
                let answer = await AnswerGenerator.generateWithOllama(results: results, query: q)
                    ?? AnswerGenerator.generate(results: results, query: q)
                let historyItem = QueryHistoryItem(
                    question: q,
                    answerText: answer.answerText,
                    sources: answer.sources
                )
                try? store.insertHistory(item: historyItem)
                await MainActor.run {
                    showReindexRequired = false
                    app.lastAnswer = answer
                    app.searchInProgress = false
                    app.refreshHistory()
                    let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    let success = !answer.sources.isEmpty && !answer.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    app.trackQuery(question: q, success: success, latencyMs: latencyMs)
                }
            }
        }
    }
}
