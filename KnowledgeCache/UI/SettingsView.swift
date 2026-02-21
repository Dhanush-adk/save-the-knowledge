//
//  SettingsView.swift
//  KnowledgeCache
//
//  Report a bug / send feedback (queued when offline, sent when online). Optional minimal analytics.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var app: AppState
    @ObservedObject private var ollamaManager: OllamaServiceManager
    @State private var message = ""
    @State private var email = ""
    @State private var feedbackType = "bug"
    @State private var submitMessage: String?
    @State private var pendingCount = 0
    @State private var flushMessage: String?
    @State private var isCheckingOllama = false
    @State private var copiedCommandMessage: String?
    @State private var queueMessage: String?
    @State private var showOllamaInstallConfirmation = false

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "v\(version) (\(build))"
    }

    init(app: AppState) {
        self.app = app
        self._ollamaManager = ObservedObject(wrappedValue: app.ollamaManager)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                reportSection
                analyticsSection
                reindexSection
                captureSection
                ingestionQueueSection
                llmSection
                appInfoSection
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
            app.refreshIngestionQueueMetrics()
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
        .alert("Install Ollama and Pull Model?", isPresented: $showOllamaInstallConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Install & Start") {
                installAndStartOllama()
            }
        } message: {
            Text("""
This runs local commands on your Mac:
1) brew install ollama
2) ollama pull \(OllamaClient.defaultModel)
3) ollama serve
""")
        }
    }

    private var appInfoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("App Info")
                .font(.headline)
            HStack {
                Text("App Version")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(appVersionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reindexSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reindex Saved Content")
                .font(.headline)
            Text("Rebuild embeddings for all saved items using the current retrieval model. Run this after retrieval or answer updates.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: { app.reindexAll() }) {
                    if app.reindexInProgress {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Label("Reindex all now", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.reindexInProgress || app.savedItems.isEmpty || !app.embedding.isAvailable)

                if app.reindexInProgress {
                    let cur = max(0, app.reindexProgressCurrent)
                    let total = max(0, app.reindexProgressTotal)
                    Text(total > 0 ? "\(cur)/\(total) chunks" : "Preparing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let status = app.reindexStatusMessage, !app.reindexInProgress {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let err = app.reindexError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !app.embedding.isAvailable {
                Text("Embedding model unavailable. Reindex is disabled until embeddings are available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private var llmSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Answer Quality")
                .font(.headline)
            Toggle(isOn: $app.useOllamaAnswers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Ollama for answer synthesis (optional)")
                        .font(.subheadline)
                    Text("If Ollama is unavailable, the app falls back to local default generation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 8) {
                Button(action: checkOllamaStatus) {
                    if isCheckingOllama {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Label("Check Ollama status", systemImage: "waveform.path.ecg")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingOllama || ollamaManager.isBusy)

                Button(action: { showOllamaInstallConfirmation = true }) {
                    if ollamaManager.isBusy {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Label("Install Ollama (Free) & Start", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(ollamaManager.isBusy || isCheckingOllama)

                Button(action: { ollamaManager.cancelInstallAndStart() }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!ollamaManager.isBusy)

                Text(ollamaManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            setupCommandRow(
                title: "1) Install Ollama (required first)",
                command: "brew install ollama"
            )
            setupCommandRow(
                title: "2) Download model",
                command: "ollama pull \(OllamaClient.defaultModel)"
            )
            setupCommandRow(
                title: "3) Start Ollama server",
                command: "ollama serve"
            )
            Text("When the app exits, it stops only the Ollama server process started by this app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let copied = copiedCommandMessage {
                Text(copied)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ingestionQueueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ingestion Queue")
                .font(.headline)
            Text("Queued jobs process in the background. Dead-letter jobs are retries exhausted and need replay.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Pending: \(app.ingestionQueuePendingCount)")
                Text("Dead-letter: \(app.ingestionQueueDeadLetterCount)")
                Text("Next retry: \(formattedRetrySeconds(app.ingestionQueueNextRetrySeconds))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Refresh") {
                    app.refreshIngestionQueueMetrics()
                }
                .buttonStyle(.bordered)

                Button("Retry now") {
                    app.retryQueuedJobsNow()
                    queueMessage = "Queued jobs are set to retry immediately."
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.ingestionQueuePendingCount == 0)

                Button("Replay dead-letter") {
                    app.replayDeadLetterJobs()
                    queueMessage = "Dead-letter jobs were moved back to pending."
                }
                .buttonStyle(.bordered)
                .disabled(app.ingestionQueueDeadLetterCount == 0)

                Button("Export diagnostics") {
                    if let fileURL = app.exportIngestionQueueDiagnostics() {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        _ = NSWorkspace.shared.open(fileURL)
                        queueMessage = "Diagnostics exported: \(fileURL.lastPathComponent)"
                    } else {
                        queueMessage = "Failed to export queue diagnostics."
                    }
                }
                .buttonStyle(.bordered)
            }

            if let queueMessage {
                Text(queueMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Auto-Save Visited Pages")
                .font(.headline)
            Toggle("Automatically save high-signal visited pages", isOn: $app.autoSaveVisitedPages)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Minimum dwell time: \(Int(app.autoSaveDwellSeconds))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Slider(value: $app.autoSaveDwellSeconds, in: 5...120, step: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Minimum scroll depth: \(Int(app.autoSaveScrollPercent))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Slider(value: $app.autoSaveScrollPercent, in: 0...100, step: 5)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Allowlist domains (comma-separated, optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("example.com, docs.python.org", text: $app.autoSaveAllowDomains)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Denylist domains (comma-separated, optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("mail.google.com, accounts.google.com", text: $app.autoSaveDenyDomains)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func setupCommandRow(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Button("Copy") {
                    copyCommand(command)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
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

    private func formattedRetrySeconds(_ seconds: Int?) -> String {
        guard let seconds else { return "none" }
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
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

    private func checkOllamaStatus() {
        isCheckingOllama = true
        Task {
            let status = await OllamaClient.checkAvailability(model: OllamaClient.defaultModel)
            await MainActor.run {
                isCheckingOllama = false
                ollamaManager.statusMessage = status.summary
            }
        }
    }

    private func installAndStartOllama() {
        Task {
            await ollamaManager.installAndStart(model: OllamaClient.defaultModel)
            await MainActor.run {
                if ollamaManager.statusMessage.contains("ready") {
                    app.useOllamaAnswers = true
                }
            }
        }
    }

    private func copyCommand(_ command: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
        copiedCommandMessage = "Copied: \(command)"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                copiedCommandMessage = nil
            }
        }
    }

    private var statusColor: Color {
        let text = ollamaManager.statusMessage.lowercased()
        if text.contains("ready") || text.contains("available") {
            return .green
        }
        if text.contains("missing") || text.contains("install") {
            return .yellow
        }
        if text.contains("failed") || text.contains("not reachable") {
            return .orange
        }
        return .secondary
    }
}
