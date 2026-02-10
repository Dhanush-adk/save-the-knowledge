//
//  SaveView.swift
//  KnowledgeCache
//
//  Save knowledge from URL or pasted text.
//

import SwiftUI

struct SaveView: View {
    @ObservedObject var app: AppState
    @State private var urlInput = ""
    @State private var pasteInput = ""
    @State private var usePaste = false
    @State private var showSuccess = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("Save Knowledge")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Add content to your offline knowledge base")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // Input type picker
                Picker("Input type", selection: $usePaste) {
                    Label("URL", systemImage: "link").tag(false)
                    Label("Paste Text", systemImage: "doc.text").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                // Input area
                if usePaste {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste content to save")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $pasteInput)
                            .font(.body)
                            .frame(minHeight: 200, maxHeight: 400)
                            .padding(12)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )

                        Text("\(pasteInput.count) characters")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter URL to fetch and save")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)
                            TextField("https://example.com/article", text: $urlInput)
                                .textFieldStyle(.plain)
                                .font(.body)
                                .onSubmit { save() }
                        }
                        .padding(12)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }
                }

                // Status: in progress (visible banner)
                if app.isSaveInProgress {
                    HStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.0)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Extracting and saving…")
                                .font(.headline)
                            Text("Loading the page and indexing. This may take 10–30 seconds.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Error display
                if let err = app.saveError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Success display (visible banner)
                if showSuccess {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text(app.saveSuccess ?? "Saved successfully!")
                            .font(.headline)
                            .foregroundStyle(.green)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Save button
                Button(action: save) {
                    HStack(spacing: 8) {
                        if app.isSaveInProgress {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                            Text("Saving…")
                        } else {
                            Image(systemName: "square.and.arrow.down.fill")
                            Text("Save to Knowledge Base")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: 300)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(app.isSaveInProgress || inputIsEmpty)

                // Stats
                if !app.savedItems.isEmpty {
                    Divider()
                        .padding(.vertical, 8)

                    HStack(spacing: 24) {
                        statBadge(count: app.savedItems.count, label: "Items saved", icon: "doc.fill")
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(32)
        }
        .animation(.easeInOut(duration: 0.3), value: showSuccess)
        .animation(.easeInOut(duration: 0.25), value: app.isSaveInProgress)
    }

    private var inputIsEmpty: Bool {
        usePaste
            ? pasteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func statBadge(count: Int, label: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.headline)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func save() {
        app.saveError = nil
        showSuccess = false
        app.isSaveInProgress = true

        if usePaste {
            AppLogger.info("Save started (pasted text, length=\(pasteInput.count))")
            let text = pasteInput
            let pipeline = app.pipeline
            Task.detached(priority: .userInitiated) {
                do {
                    let item = try pipeline.ingestPastedText(text)
                    AppLogger.info("Save success: \(item.title)")
                    await MainActor.run {
                        app.refreshItems()
                        pasteInput = ""
                        app.isSaveInProgress = false
                        app.saveSuccess = "Saved: \(item.title)"
                        showSuccess = true
                        dismissSuccessAfterDelay()
                    }
                } catch {
                    AppLogger.error("Save failed (pasted): \(error.localizedDescription)")
                    await MainActor.run {
                        app.saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        app.isSaveInProgress = false
                    }
                }
            }
        } else {
            guard let url = URL(string: urlInput.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
                AppLogger.warning("Save aborted: invalid URL")
                app.saveError = "Please enter a valid URL (e.g. https://example.com)"
                app.isSaveInProgress = false
                return
            }
            AppLogger.info("Save started: \(url.absoluteString)")
            let pipeline = app.pipeline
            Task.detached(priority: .userInitiated) {
                do {
                    let item = try await pipeline.ingest(url: url)
                    AppLogger.info("Save success: \(item.title) (\(url.absoluteString))")
                    await MainActor.run {
                        app.refreshItems()
                        urlInput = ""
                        app.isSaveInProgress = false
                        app.saveSuccess = "Saved: \(item.title)"
                        showSuccess = true
                        dismissSuccessAfterDelay()
                    }
                } catch {
                    AppLogger.error("Save failed (\(url.absoluteString)): \(error.localizedDescription)")
                    await MainActor.run {
                        app.saveError = error.localizedDescription
                        app.isSaveInProgress = false
                    }
                }
            }
        }
    }

    private func dismissSuccessAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation {
                showSuccess = false
            }
        }
    }
}
