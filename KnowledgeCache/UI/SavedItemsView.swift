//
//  SavedItemsView.swift
//  KnowledgeCache
//
//  Browse and manage saved knowledge items.
//

import SwiftUI

struct SavedItemsView: View {
    @ObservedObject var app: AppState
    @State private var showReindexError = false
    @State private var selectedItem: KnowledgeItem?
    @State private var searchText = ""

    private var filteredItems: [KnowledgeItem] {
        if searchText.isEmpty { return app.savedItems }
        let q = searchText.lowercased()
        return app.savedItems.filter {
            $0.title.lowercased().contains(q) ||
            $0.sourceDisplay.lowercased().contains(q) ||
            $0.rawContent.lowercased().contains(q)
        }
    }

    var body: some View {
        HSplitView {
            // List panel
            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Filter items...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                if filteredItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text(app.savedItems.isEmpty ? "No items saved yet" : "No matching items")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        if app.savedItems.isEmpty {
                            Text("Go to Save to add content")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedItem) {
                        ForEach(filteredItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(2)

                                HStack(spacing: 6) {
                                    if item.url != nil {
                                        Image(systemName: "link")
                                            .font(.caption2)
                                    } else {
                                        Image(systemName: "doc.text")
                                            .font(.caption2)
                                    }
                                    Text(item.sourceDisplay)
                                        .lineLimit(1)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                Text(item.createdAt, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                if item.wasTruncated {
                                    Label("Truncated", systemImage: "exclamationmark.triangle")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(item)
                            .contextMenu {
                                Button(role: .destructive) {
                                    app.deleteItem(item)
                                    if selectedItem?.id == item.id { selectedItem = nil }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for idx in indexSet {
                                let item = filteredItems[idx]
                                app.deleteItem(item)
                                if selectedItem?.id == item.id { selectedItem = nil }
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }

                Divider()

                // Bottom toolbar
                HStack(spacing: 12) {
                    Text("\(app.savedItems.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: { app.optimizeStorage() }) {
                        Label("Optimize", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(app.savedItems.isEmpty)

                    Button(action: { app.reindexAll() }) {
                        Label("Re-index", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(app.reindexInProgress || app.savedItems.isEmpty || !app.embedding.isAvailable)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(minWidth: 260, idealWidth: 300)

            // Detail panel
            if let item = selectedItem {
                itemDetail(item)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Select an item to view details")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if app.reindexInProgress {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Re-indexing embeddings...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: app.reindexError) { _, new in
            if new != nil { showReindexError = true }
        }
        .alert("Re-index Error", isPresented: $showReindexError) {
            Button("OK", role: .cancel) {
                app.reindexError = nil
                showReindexError = false
            }
        } message: {
            if let err = app.reindexError { Text(err) }
        }
    }

    private func itemDetail(_ item: KnowledgeItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title
                Text(item.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .textSelection(.enabled)

                // Metadata
                HStack(spacing: 16) {
                    Label(item.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    if let url = item.url {
                        Label {
                            Link(url, destination: URL(string: url) ?? URL(string: "about:blank")!)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "link")
                        }
                    } else {
                        Label("Pasted text", systemImage: "doc.text")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let hash = item.contentHash {
                    Label("Hash: \(String(hash.prefix(16)))...", systemImage: "number")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                // Content preview
                Text("Content Preview")
                    .font(.headline)

                Text(String(item.rawContent.prefix(2000)))
                    .font(.body)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if item.rawContent.count > 2000 {
                    Text("... \(item.rawContent.count - 2000) more characters")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Delete button
                Divider()
                    .padding(.top, 8)

                Button(role: .destructive) {
                    app.deleteItem(item)
                    selectedItem = nil
                } label: {
                    Label("Delete Item", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// Make KnowledgeItem Hashable for List selection
extension KnowledgeItem: Hashable {
    static func == (lhs: KnowledgeItem, rhs: KnowledgeItem) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
