//
//  ContentView.swift
//  KnowledgeCache
//
//  Main navigation with sidebar-style tabs.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var app = AppState()
    @State private var selectedTab: Tab = .chat
    @AppStorage("KnowledgeCache.onboardingCompleted") private var onboardingCompleted = false
    @State private var showGuidedSetup = false
    @State private var hasPresentedSetup = false

    enum Tab: String, CaseIterable {
        case chat = "Chat"
        case settings = "Settings"
        case web = "Web"
        case save = "Save"
        case saved = "Library"
        case history = "Usage Analytics"

        var icon: String {
            switch self {
            case .chat: return "bubble.left.and.bubble.right.fill"
            case .web: return "globe"
            case .save: return "plus.circle.fill"
            case .saved: return "books.vertical.fill"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section("Navigate") {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Label(tab.rawValue, systemImage: tab.icon)
                            .tag(tab)
                    }
                }
                SidebarUpdateSection(updater: app.appUpdateManager)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Group {
                switch selectedTab {
                case .chat:
                    ChatView(app: app)
                case .web:
                    WebSearchView(app: app)
                case .save:
                    SaveView(app: app)
                case .saved:
                    SavedItemsView(app: app)
                case .history:
                    HistoryView(app: app)
                case .settings:
                    SettingsView(app: app)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selectedTab.rawValue)
        .frame(minWidth: 700, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showGuidedSetup = true
                } label: {
                    Label("Guided Setup", systemImage: "questionmark.circle")
                }
            }
        }
        .sheet(isPresented: $showGuidedSetup) {
            GuidedSetupSheet(
                selectedTab: $selectedTab,
                onboardingCompleted: $onboardingCompleted
            )
        }
        .onAppear {
            app.refreshItems()
            app.refreshHistory()
            app.refreshChatThreads()
            Task { await app.appUpdateManager.checkForUpdates() }
            if !onboardingCompleted, !hasPresentedSetup {
                hasPresentedSetup = true
                showGuidedSetup = true
            }
        }
    }
}

private struct SidebarUpdateSection: View {
    @ObservedObject var updater: AppUpdateManager

    var body: some View {
        Section("App Update") {
            HStack(spacing: 8) {
                if updater.isChecking || updater.isUpgrading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: updater.isUpdateAvailable ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(updater.isUpdateAvailable ? .orange : .green)
                }
                Text(updater.statusMessage)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Check") {
                    Task { await updater.checkForUpdates() }
                }
                .buttonStyle(.bordered)
                .disabled(updater.isChecking || updater.isUpgrading)

                if updater.restartRequiredAfterUpgrade {
                    Button("Restart") {
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.isUpgrading || updater.isChecking)
                } else if updater.isUpdateAvailable {
                    Button("Upgrade") {
                        Task { await updater.upgradeToLatest() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.isUpgrading || updater.isChecking)
                }

                if updater.isUpgrading {
                    Button("Stop") {
                        updater.cancelUpgrade()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
    }
}

private struct GuidedSetupStep: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let actionTitle: String
    let targetTab: ContentView.Tab
}

private struct GuidedSetupSheet: View {
    @Binding var selectedTab: ContentView.Tab
    @Binding var onboardingCompleted: Bool
    @State private var stepIndex = 0
    @Environment(\.dismiss) private var dismiss

    private let steps: [GuidedSetupStep] = [
        GuidedSetupStep(
            title: "1) Check Ollama status (optional)",
            detail: "Open Settings and click 'Check Ollama status'. This tells you if local AI is ready. You can use the app without Ollama too.",
            actionTitle: "Open Settings",
            targetTab: .settings
        ),
        GuidedSetupStep(
            title: "2) Install Ollama and model (optional)",
            detail: "If you want richer answers, run Ollama setup in Settings. You can stop the setup any time with the Stop button.",
            actionTitle: "Open Settings",
            targetTab: .settings
        ),
        GuidedSetupStep(
            title: "3) Browse and save from Web",
            detail: "Open Web, paste a URL, open the page, then click 'Save to offline'. For YouTube links, we save what is accessible and you can manually add notes/transcript for better results.",
            actionTitle: "Open Web",
            targetTab: .web
        ),
        GuidedSetupStep(
            title: "4) Manually save URL or text",
            detail: "Open Save if you want direct control. You can paste a URL manually or paste plain text/notes and save it instantly.",
            actionTitle: "Open Save",
            targetTab: .save
        ),
        GuidedSetupStep(
            title: "5) Ask in Chat, then archive/delete",
            detail: "Open Chat, ask a question, then use New Chat / archive / delete controls to organize your conversations.",
            actionTitle: "Open Chat",
            targetTab: .chat
        ),
        GuidedSetupStep(
            title: "6) Reindex when needed",
            detail: "If retrieval quality changes or you import many items, run Reindex from Settings or Library to refresh embeddings.",
            actionTitle: "Open Library",
            targetTab: .saved
        )
    ]

    private var current: GuidedSetupStep { steps[stepIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Save the Knowledge")
                .font(.title2.weight(.semibold))
            Text("Follow this quick setup once. You can reopen it any time from 'Guided Setup'.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text(current.title)
                    .font(.headline)
                Text(current.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Text("Step \(stepIndex + 1) of \(steps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(current.actionTitle) {
                    selectedTab = current.targetTab
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Button("Back") {
                    stepIndex = max(0, stepIndex - 1)
                }
                .disabled(stepIndex == 0)

                Spacer()

                Button(stepIndex == steps.count - 1 ? "Finish" : "Next") {
                    if stepIndex == steps.count - 1 {
                        onboardingCompleted = true
                        dismiss()
                    } else {
                        stepIndex += 1
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()
            HStack {
                Button("Skip for now") {
                    dismiss()
                }
                Spacer()
                Button("Mark complete") {
                    onboardingCompleted = true
                    dismiss()
                }
            }
            .font(.caption)
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620)
    }
}
