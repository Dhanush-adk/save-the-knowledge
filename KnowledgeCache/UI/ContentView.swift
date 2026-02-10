//
//  ContentView.swift
//  KnowledgeCache
//
//  Main navigation with sidebar-style tabs.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppState()
    @State private var selectedTab: Tab = .search

    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "v\(version) (\(build))"
    }

    enum Tab: String, CaseIterable {
        case search = "Search"
        case save = "Save"
        case saved = "Library"
        case history = "History"

        var icon: String {
            switch self {
            case .search: return "magnifyingglass"
            case .save: return "plus.circle.fill"
            case .saved: return "books.vertical.fill"
            case .history: return "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Group {
                switch selectedTab {
                case .search:
                    SearchView(app: app)
                case .save:
                    SaveView(app: app)
                case .saved:
                    SavedItemsView(app: app)
                case .history:
                    HistoryView(app: app)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selectedTab.rawValue)
        .frame(minWidth: 700, minHeight: 500)
        .overlay(alignment: .bottomTrailing) {
            Text(appVersion)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .onAppear {
            app.refreshItems()
            app.refreshHistory()
        }
    }
}
