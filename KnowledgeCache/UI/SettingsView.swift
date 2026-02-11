//
//  SettingsView.swift
//  KnowledgeCache
//
//  Report a bug / send feedback (queued when offline, sent when online). Optional minimal analytics.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var app: AppState
    @State private var message = ""
    @State private var email = ""
    @State private var feedbackType = "bug"
    @State private var submitMessage: String?
    @State private var pendingCount = 0
    @State private var flushMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                reportSection
                analyticsSection
                if pendingCount > 0 {
                    pendingBanner
                }
                if let msg = submitMessage {
                    Text(msg)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let msg = flushMessage {
                    Text(msg)
                        .font(.subheadline)
                        .foregroundStyle(msg.hasPrefix("Send failed") ? .red : .secondary)
                }
            }
            .padding(24)
        }
        .onAppear {
            pendingCount = app.feedbackReporter.pendingCount()
            if app.networkMonitor.isConnected, pendingCount > 0 {
                app.feedbackReporter.flushPendingFeedback(isConnected: true)
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run { pendingCount = app.feedbackReporter.pendingCount() }
                }
            }
        }
        .onChange(of: app.networkMonitor.isConnected) { _, _ in
            pendingCount = app.feedbackReporter.pendingCount()
        }
    }

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a bug or send feedback")
                .font(.headline)
            Text("When you're offline, reports are saved and sent automatically when you're back online.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Type", selection: $feedbackType) {
                Text("Bug").tag("bug")
                Text("Feedback").tag("feedback")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            TextField("Your message (required)", text: $message, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...8)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            TextField("Email (optional)", text: $email)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: submitFeedback) {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                    Text("Send")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var analyticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anonymous usage")
                .font(.headline)
            Toggle(isOn: Binding(
                get: { app.feedbackReporter.isAnalyticsEnabled },
                set: { app.feedbackReporter.isAnalyticsEnabled = $0 }
            )) {
                Text("Send minimal usage stats when online (e.g. app version, saves count, once per day)")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
        }
    }

    private var pendingBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(.secondary)
                Text("\(pendingCount) report(s) will be sent when you're back online.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if app.networkMonitor.isConnected {
                Button(action: sendPendingNow) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Send now")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sendPendingNow() {
        flushMessage = nil
        app.feedbackReporter.flushPendingFeedback(isConnected: true) { [self] sent, error in
            pendingCount = app.feedbackReporter.pendingCount()
            if sent > 0, error == nil {
                flushMessage = "Sent \(sent) report(s)."
            } else if let err = error {
                flushMessage = "Send failed: \(err)"
            }
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run { flushMessage = nil }
            }
        }
    }

    private func submitFeedback() {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        let emailTrim = email.trimmingCharacters(in: .whitespacesAndNewlines)
        app.feedbackReporter.submit(
            message: msg,
            email: emailTrim.isEmpty ? nil : emailTrim,
            type: feedbackType,
            isConnected: app.networkMonitor.isConnected
        )
        message = ""
        email = ""
        pendingCount = app.feedbackReporter.pendingCount()
        submitMessage = app.networkMonitor.isConnected
            ? "Thanks. Your report was sent."
            : "Saved. It will be sent when you're back online."
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                submitMessage = nil
            }
        }
    }
}
