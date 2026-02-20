//
//  ChatView.swift
//  KnowledgeCache
//
//  Persistent chat UI backed by local conversation storage.
//

import SwiftUI

struct ChatView: View {
    @ObservedObject var app: AppState
    @State private var draft = ""
    @State private var sourceOpenError: String?
    @State private var showRenameSheet = false
    @State private var renameDraft = ""

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 960
            HSplitView {
                threadSidebar(compact: compact)
                    .frame(minWidth: compact ? 200 : 250, idealWidth: compact ? 230 : 290, maxWidth: compact ? 280 : 360)

                VStack(spacing: 0) {
                    headerBar(compact: compact)
                    if let sourceOpenError {
                        banner(sourceOpenError, color: .orange)
                            .padding(.horizontal, compact ? 10 : 16)
                            .padding(.top, 10)
                    }
                    if let chatError = app.chatError {
                        banner(chatError, color: .red)
                            .padding(.horizontal, compact ? 10 : 16)
                            .padding(.top, 10)
                    }
                    if let update = app.availableAppUpdate {
                        updateBanner(update)
                            .padding(.horizontal, compact ? 10 : 16)
                            .padding(.top, 10)
                    }
                    messageTimeline(compact: compact)
                    if !app.activeChatMessages.isEmpty {
                        composer(compact: compact)
                    }
                }
            }
        }
        .onAppear {
            app.refreshChatThreads()
            Task {
                await app.refreshOllamaAvailability()
                await app.refreshAppUpdateInfo()
            }
        }
    }

    private func headerBar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 0) {
            HStack(spacing: 10) {
                Text("Ask your knowledge base")
                    .font(compact ? .headline.weight(.semibold) : .title3.weight(.semibold))

                Spacer()

                HStack(spacing: 8) {
                    Circle()
                        .fill(app.ollamaAvailability.isServerReachable ? (app.ollamaAvailability.isModelAvailable ? Color.green : Color.orange) : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(app.ollamaAvailability.isModelAvailable ? "Ollama ready" : "Ollama unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if compact {
                modeSelector
            } else {
                HStack {
                    Spacer()
                    modeSelector
                }
            }
        }
        .padding(.horizontal, compact ? 10 : 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.04))
    }

    private var modeSelector: some View {
        HStack(spacing: 6) {
            modeButton(title: ChatAnswerMode.grounded.title, mode: .grounded, enabled: true)
            modeButton(
                title: ChatAnswerMode.ollama.title,
                mode: .ollama,
                enabled: app.ollamaAvailability.isServerReachable && app.ollamaAvailability.isModelAvailable
            )
        }
        .padding(4)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }

    private func modeButton(title: String, mode: ChatAnswerMode, enabled: Bool) -> some View {
        Button {
            guard enabled else { return }
            app.chatAnswerMode = mode
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(app.chatAnswerMode == mode ? Color.white : (enabled ? Color.primary : Color.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(app.chatAnswerMode == mode ? Color.accentColor : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(modeHelpText(mode: mode, enabled: enabled))
    }

    private func threadSidebar(compact: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        app.createNewChat()
                    } label: {
                        Label("New Chat", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(compact ? .small : .regular)
                    .help("Create a new chat conversation.")

                    Button {
                        guard app.selectedChatThreadId != nil else { return }
                        renameDraft = app.chatThreads.first(where: { $0.id == app.selectedChatThreadId })?.title ?? ""
                        showRenameSheet = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(compact ? .small : .regular)
                    .opacity(app.selectedChatThreadId == nil ? 0.45 : 1.0)
                    .help("Rename the selected chat.")

                    Button {
                        guard app.selectedChatThreadId != nil else { return }
                        app.deleteSelectedChat()
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(compact ? .small : .regular)
                    .opacity(app.selectedChatThreadId == nil ? 0.45 : 1.0)
                    .help("Archive the selected chat.")

                    Button(role: .destructive) {
                        guard app.selectedChatThreadId != nil else { return }
                        app.permanentlyDeleteSelectedChat()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(compact ? .small : .regular)
                    .opacity(app.selectedChatThreadId == nil ? 0.45 : 1.0)
                    .help("Permanently delete the selected chat.")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider()

            if app.chatThreads.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No chats yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    List(selection: Binding(
                        get: { app.selectedChatThreadId },
                        set: { id in
                            if let id {
                                app.loadChatThread(id: id)
                            }
                        }
                    )) {
                        ForEach(app.chatThreads) { thread in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(thread.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                if !thread.lastMessagePreview.isEmpty {
                                    Text(thread.lastMessagePreview)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text(thread.updatedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .tag(thread.id)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))

                    if !app.archivedChatThreads.isEmpty {
                        Divider()
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Archived Chats")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(app.archivedChatThreads.prefix(20)) { thread in
                                        HStack(spacing: 8) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(thread.title)
                                                    .font(.caption.weight(.medium))
                                                    .lineLimit(1)
                                                Text(thread.archivedAt ?? thread.updatedAt, style: .relative)
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            Spacer(minLength: 8)
                                            Button("Restore") {
                                                app.restoreArchivedChat(threadId: thread.id)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                            .help("Restore this archived chat.")
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                            .frame(maxHeight: 180)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename Conversation")
                    .font(.headline)
                TextField("Conversation title", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        showRenameSheet = false
                    }
                    Button("Save") {
                        app.renameSelectedChat(to: renameDraft)
                        showRenameSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(minWidth: 360, minHeight: 140)
        }
    }

    private func messageTimeline(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if app.activeChatMessages.isEmpty {
                        emptyStateComposer
                            .frame(maxWidth: .infinity, minHeight: compact ? 360 : 540, alignment: .center)
                    } else {
                        ForEach(app.activeChatMessages) { message in
                            if shouldRender(message) {
                                messageBubble(message, compact: compact)
                                    .id(message.id)
                            }
                        }
                    }

                    if app.chatInProgress && !isAssistantStreaming {
                        HStack(spacing: 10) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Thinking...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(compact ? 10 : 16)
            }
            .onChange(of: app.activeChatMessages.count) { _, _ in
                if let lastId = app.activeChatMessages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: app.activeChatMessages.last?.content ?? "") { _, content in
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let lastId = app.activeChatMessages.last?.id else { return }
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    private var emptyStateComposer: some View {
        VStack(spacing: 14) {
            Text("Ask your knowledge base")
                .font(.system(size: 34, weight: .semibold))
            Text("Grounded answers from your local sources, with citations.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            composerInput(isLarge: true)
                .frame(maxWidth: 920)
        }
        .frame(maxWidth: .infinity)
    }

    private func messageBubble(_ message: ChatMessage, compact: Bool) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            HStack {
                if message.role == .user { Spacer(minLength: compact ? 12 : 48) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.content)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .foregroundStyle(message.role == .user ? .white : .primary)
                }
                .padding(12)
                .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                if message.role == .assistant { Spacer(minLength: compact ? 12 : 48) }
            }

            if message.role == .assistant, !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sources")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(message.sources) { src in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: src.url != nil ? "link" : "doc.text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                if src.url != nil {
                                    Button(src.title) {
                                        sourceOpenError = app.openCitationSource(url: src.url)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption.weight(.semibold))
                                } else {
                                    Text(src.title)
                                        .font(.caption.weight(.semibold))
                                }
                                Text(src.snippet)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            if message.role == .assistant, !message.suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(message.suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                app.sendChatMessage(suggestion)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func composer(compact: Bool) -> some View {
        composerInput(isLarge: false, compact: compact)
            .padding(.horizontal, compact ? 10 : 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
    }

    private var isAssistantStreaming: Bool {
        guard let last = app.activeChatMessages.last else { return false }
        return last.role == .assistant && !last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shouldRender(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return true }
        guard app.chatInProgress else { return true }
        guard message.id == app.activeChatMessages.last?.id else { return true }
        return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func modeHelpText(mode: ChatAnswerMode, enabled: Bool) -> String {
        switch mode {
        case .grounded:
            return "Knowledge Base mode: answers are generated directly from your saved local sources."
        case .ollama:
            if enabled {
                return "Ollama mode: answers are generated using your local Ollama model on top of retrieved knowledge-base context."
            }
            return "Ollama mode is unavailable until Ollama is running and the model is ready."
        }
    }

    private func composerInput(isLarge: Bool, compact: Bool = false) -> some View {
        let canSend = !app.chatInProgress && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .center, spacing: 0) {
            TextField("Ask your knowledge base...", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...(isLarge ? 5 : 4))
                .font(isLarge ? (compact ? .body : .title3.weight(.regular)) : .body)
                .padding(.horizontal, 16)
                .padding(.vertical, isLarge ? 10 : 9)
                .onSubmit(sendDraft)

            Divider()
                .frame(height: isLarge ? 34 : 30)
                .padding(.trailing, 8)

            Button {
                sendDraft()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .frame(width: isLarge ? (compact ? 52 : 60) : (compact ? 46 : 54), height: isLarge ? (compact ? 40 : 46) : (compact ? 36 : 42))
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(canSend ? Color.accentColor : Color.accentColor.opacity(0.35))
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: isLarge ? (compact ? 700 : 920) : .infinity)
        .frame(minHeight: isLarge ? 62 : 56)
        .padding(.horizontal, isLarge ? 2 : 8)
        .padding(.vertical, isLarge ? 2 : 6)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.07), radius: 10, x: 0, y: 4)
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        app.sendChatMessage(text)
    }

    private func updateBanner(_ update: FeedbackReporter.AppUpdateInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
            Text(update.isUpgradeRequired ? "Upgrade required" : "Update available")
                .font(.caption.weight(.semibold))
            Text("\(update.latestVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let link = update.downloadURL, let url = URL(string: link) {
                Link("Upgrade", destination: url)
                    .font(.caption.weight(.semibold))
            }
            Button("Dismiss") {
                app.dismissAvailableAppUpdate()
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func banner(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
