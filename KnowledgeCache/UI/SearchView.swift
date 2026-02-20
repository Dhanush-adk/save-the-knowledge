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
    @State private var sourceOpenError: String?
    @State private var expandedEvidence: Set<UUID> = []
    @State private var lastSubmittedQuery: String = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
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
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let err = app.searchError {
                        alertBanner(err, color: .red)
                    }

                    if showReindexRequired {
                        alertBanner("Embedding dimension changed. Go to Library > Re-index all to fix.", color: .orange)
                    }

                    if let sourceOpenError {
                        alertBanner(sourceOpenError, color: .orange)
                    }

                    if app.savedItems.isEmpty && !app.searchInProgress {
                        emptyState
                    } else if let answer = app.lastAnswer {
                        answerView(answer, query: lastSubmittedQuery)
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

    private func answerView(_ answer: AnswerWithSources, query: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if !query.isEmpty {
                HStack {
                    Spacer(minLength: 32)
                    Text(query)
                        .textSelection(.enabled)
                        .font(.body)
                        .padding(12)
                        .foregroundStyle(.white)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            HStack {
                Text(answer.answerText)
                    .textSelection(.enabled)
                    .font(.body)
                    .lineSpacing(4)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 32)
            }

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
                                if src.url != nil {
                                    Button {
                                        sourceOpenError = app.openCitationSource(url: src.url)
                                    } label: {
                                        Text(src.title)
                                            .lineLimit(1)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                    }
                                    .buttonStyle(.plain)
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

                VStack(alignment: .leading, spacing: 10) {
                    Label("Evidence Excerpts", systemImage: "quote.bubble.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("Expand a source to verify the exact retrieved excerpt used for this answer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(answer.sources.enumerated()), id: \.element.id) { idx, src in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedEvidence.contains(src.id) },
                                set: { isExpanded in
                                    if isExpanded {
                                        expandedEvidence.insert(src.id)
                                    } else {
                                        expandedEvidence.remove(src.id)
                                    }
                                }
                            )
                        ) {
                            Text(src.snippet)
                                .font(.caption)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } label: {
                            HStack(spacing: 8) {
                                Text("[S\(idx + 1)]")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)

                                if src.url != nil {
                                    Button {
                                        sourceOpenError = app.openCitationSource(url: src.url)
                                    } label: {
                                        Text(src.title)
                                            .lineLimit(1)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Text(src.title)
                                        .lineLimit(1)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.secondary.opacity(0.05))
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

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        lastSubmittedQuery = q
        let startedAt = Date()
        app.searchError = nil
        app.lastAnswer = nil
        app.searchInProgress = true

        runSemanticSearch(
            query: q,
            search: app.search,
            store: app.store,
            useOllama: app.useOllamaAnswers,
            startedAt: startedAt
        )
    }

    private func runSemanticSearch(
        query q: String,
        search: SemanticSearch,
        store: KnowledgeStore,
        useOllama: Bool,
        startedAt: Date
    ) {
        Task.detached(priority: .userInitiated) {
            let outcome = search.search(query: q, topK: 12)
            switch outcome {
            case .reindexRequired:
                await MainActor.run {
                    self.showReindexRequired = true
                    self.app.lastAnswer = nil
                    self.app.searchInProgress = false
                    let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    self.app.trackQuery(question: q, success: false, latencyMs: latencyMs)
                }
            case .results(let results):
                let answer: AnswerWithSources
                if useOllama {
                    answer = await AnswerGenerator.generateWithOllama(results: results, query: q)
                        ?? AnswerGenerator.generate(results: results, query: q)
                } else {
                    answer = AnswerGenerator.generate(results: results, query: q)
                }
                let historyItem = QueryHistoryItem(
                    question: q,
                    answerText: answer.answerText,
                    sources: answer.sources
                )
                try? store.insertHistory(item: historyItem)
                await MainActor.run {
                    self.showReindexRequired = false
                    self.app.lastAnswer = answer
                    self.app.searchInProgress = false
                    self.app.refreshHistory()
                    let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    let success = !answer.sources.isEmpty && !answer.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    self.app.trackQuery(question: q, success: success, latencyMs: latencyMs)
                }
            }
        }
    }
}
