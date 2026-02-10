//
//  HistoryView.swift
//  KnowledgeCache
//
//  Browse past questions and answers.
//

import SwiftUI

struct HistoryView: View {
    @ObservedObject var app: AppState
    @State private var selectedId: UUID?

    var body: some View {
        HSplitView {
            // Question list
            VStack(spacing: 0) {
                if app.historyItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("No questions asked yet")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        Text("Search your knowledge base to build history")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedId) {
                        ForEach(app.historyItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.question)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(2)

                                HStack(spacing: 4) {
                                    Text(item.createdAt, style: .date)
                                    Text("at")
                                    Text(item.createdAt, style: .time)
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)

                                if !item.sources.isEmpty {
                                    Text("\(item.sources.count) source\(item.sources.count == 1 ? "" : "s")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(item.id)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }

                Divider()

                HStack {
                    Text("\(app.historyItems.count) queries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(minWidth: 240, idealWidth: 280)

            // Detail panel
            if let id = selectedId, let item = app.historyItems.first(where: { $0.id == id }) {
                historyDetail(item)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Select a question to view details")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func historyDetail(_ item: QueryHistoryItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Question
                VStack(alignment: .leading, spacing: 6) {
                    Label("Question", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.question)
                        .font(.title3)
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                }

                // Timestamp
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                // Answer
                VStack(alignment: .leading, spacing: 8) {
                    Label("Answer", systemImage: "lightbulb.fill")
                        .font(.headline)

                    Text(item.answerText)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Sources
                if !item.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Sources", systemImage: "doc.text.fill")
                            .font(.headline)

                        ForEach(item.sources) { src in
                            HStack(alignment: .top, spacing: 10) {
                                if let kid = src.knowledgeItemId, !app.itemExists(id: kid) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                        .frame(width: 16)
                                } else {
                                    Image(systemName: src.url != nil ? "link" : "doc.text")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    if let kid = src.knowledgeItemId, !app.itemExists(id: kid) {
                                        Text("\(src.title) (deleted)")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .strikethrough()
                                    } else if let urlString = src.url, let url = URL(string: urlString) {
                                        Link(destination: url) {
                                            Text(src.title)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                        }
                                    } else {
                                        Text(src.title)
                                            .font(.subheadline)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .background(Color.secondary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
