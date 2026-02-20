//
//  HistoryView.swift
//  KnowledgeCache
//
//  Chat analytics dashboard.
//

import SwiftUI

struct HistoryView: View {
    @ObservedObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Conversation Analytics")
                    .font(.title2.weight(.semibold))

                if let metrics = app.chatAnalytics {
                    metricGrid(metrics: metrics)
                    topConversations
                    healthSection(metrics: metrics)
                } else {
                    Text("No analytics yet. Start chatting to populate metrics.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .onAppear {
            app.refreshChatAnalytics()
        }
    }

    private func metricGrid(metrics: KnowledgeStore.ChatAnalyticsSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard("Active conversations", value: "\(metrics.activeThreads)")
            metricCard("Archived conversations", value: "\(metrics.archivedThreads)")
            metricCard("Total messages", value: "\(metrics.totalMessages)")
            metricCard("Avg messages/conversation", value: String(format: "%.1f", metrics.avgMessagesPerActiveThread))
            metricCard("Assistant messages", value: "\(metrics.assistantMessages)")
            metricCard("Source hit rate", value: "\(Int(metrics.sourceHitRate * 100))%")
        }
    }

    private var topConversations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Conversations")
                .font(.headline)

            if app.topChatThreadStats.isEmpty {
                Text("No active conversations yet.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(app.topChatThreadStats) { stat in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stat.thread.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if !stat.thread.lastMessagePreview.isEmpty {
                                Text(stat.thread.lastMessagePreview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(stat.messageCount) msgs")
                                .font(.caption.weight(.semibold))
                            Text("\(stat.userMessageCount) user / \(stat.assistantMessageCount) assistant")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func healthSection(metrics: KnowledgeStore.ChatAnalyticsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quality Signals")
                .font(.headline)
            Text("Assistant responses with citations: \(metrics.assistantMessagesWithSources)/\(max(metrics.assistantMessages, 1))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let mostRecent = metrics.mostRecentMessageAt {
                Text("Most recent conversation activity: \(mostRecent.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func metricCard(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
