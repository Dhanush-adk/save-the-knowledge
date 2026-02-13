//
//  WebSearchView.swift
//  KnowledgeCache
//
//  Browse the web (DuckDuckGo search or any URL). "Save to offline" stores the
//  current page in the local knowledge base for later search. No paid APIs.
//

import SwiftUI
import WebKit

// MARK: - Web Search View
private struct BrowserTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var currentURL: URL?
    var pendingLoadURL: URL?
    var isLoading: Bool

    init(initialURL: URL) {
        self.id = UUID()
        self.title = "New Tab"
        self.currentURL = initialURL
        self.pendingLoadURL = initialURL
        self.isLoading = false
    }
}

struct WebSearchView: View {
    @ObservedObject var app: AppState
    @State private var searchOrURL = ""
    @State private var saveSuccessVisible = false
    @State private var hasLoadedInitial = false
    @State private var tabs: [BrowserTab] = []
    @State private var selectedTabID: UUID?
    @FocusState private var isSearchFocused: Bool

    private static let duckDuckGoBase = "https://duckduckgo.com/"
    private static let searchEngineHosts = ["duckduckgo.com", "google.com", "bing.com", "www.duckduckgo.com", "www.google.com", "www.bing.com"]
    private var initialURL: URL { URL(string: Self.duckDuckGoBase)! }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            toolbar
            if app.isSaveInProgress || app.saveError != nil || saveSuccessVisible || app.saveJobState != .idle {
                saveStatusBanner
            }
            Divider()
            ZStack {
                ForEach(tabs) { tab in
                    BrowserWebView(
                        urlToLoad: binding(for: tab.id, keyPath: \.pendingLoadURL),
                        currentURL: binding(for: tab.id, keyPath: \.currentURL),
                        isLoading: binding(for: tab.id, keyPath: \.isLoading),
                        pageTitle: binding(for: tab.id, keyPath: \.title)
                    )
                    .opacity(tab.id == selectedTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == selectedTabID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: app.saveSuccess) { _, newValue in
            if newValue != nil {
                saveSuccessVisible = true
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await MainActor.run {
                        saveSuccessVisible = false
                        app.saveSuccess = nil
                    }
                }
            }
        }
        .onAppear {
            if !hasLoadedInitial {
                hasLoadedInitial = true
                let first = BrowserTab(initialURL: initialURL)
                tabs = [first]
                selectedTabID = first.id
                searchOrURL = initialURL.absoluteString
            }
        }
        .onChange(of: selectedTabID) { _, newID in
            guard let id = newID, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
            searchOrURL = tabs[idx].currentURL?.absoluteString ?? ""
        }
        .onChange(of: tabs) { _, _ in
            guard let tab = selectedTab else { return }
            if let u = tab.currentURL {
                searchOrURL = u.absoluteString
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs) { tab in
                    HStack(spacing: 6) {
                        Button(action: { selectedTabID = tab.id }) {
                            Text(tabLabel(tab))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 180, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        if tabs.count > 1 {
                            Button(action: { closeTab(tab.id) }) {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .help("Close tab")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((tab.id == selectedTabID ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }

                Button(action: newTab) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .help("New tab")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("Back")

            Button(action: goForward) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .help("Forward")

            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Reload")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search or enter URL", text: $searchOrURL)
                    .textFieldStyle(.plain)
                    .onSubmit { loadSearchOrURL() }
                    .focused($isSearchFocused)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button("Go") {
                loadSearchOrURL()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Spacer(minLength: 8)

            Button(action: saveCurrentPageToOffline) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("Save to offline")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!canSaveCurrentPage || app.isSaveInProgress)
            .help(canSaveCurrentPage ? "Save this page to your offline knowledge base for later search" : "Open an article or page (not a search results page) to save it offline")
            .accessibilityLabel("Save to offline")
            .accessibilityHint(canSaveCurrentPage ? "Saves the current page for offline search" : "Navigate to a content page first")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var saveStatusBanner: some View {
        Group {
            if case .queued = app.saveJobState {
                HStack(spacing: 12) {
                    ProgressView().scaleEffect(0.9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Queued for offline save…")
                            .font(.subheadline.weight(.medium))
                        Text("Preparing page extraction job.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12))
            } else if case .indexing = app.saveJobState {
                HStack(spacing: 12) {
                    ProgressView().scaleEffect(0.9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Indexing for offline search…")
                            .font(.subheadline.weight(.medium))
                        Text("Extracting, chunking, and embedding. This may take 10–30 seconds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12))
            } else if let err = app.saveError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
            } else if saveSuccessVisible, let message = app.saveSuccess {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12))
            }
        }
    }

    private var canSaveCurrentPage: Bool {
        guard let url = selectedTab?.currentURL else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return !Self.searchEngineHosts.contains(host)
    }

    private func loadSearchOrURL() {
        let input = searchOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard let idx = selectedTabIndex else { return }
        if let url = parseAsURL(input) {
            tabs[idx].pendingLoadURL = url
            tabs[idx].currentURL = url
        } else {
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: " ")
            let query = input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
            let searchURL = URL(string: Self.duckDuckGoBase + "?q=" + query)!
            tabs[idx].pendingLoadURL = searchURL
            tabs[idx].currentURL = searchURL
        }
    }

    private func parseAsURL(_ input: String) -> URL? {
        if input.contains(".") && !input.contains(" ") {
            var s = input
            if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
                s = "https://" + s
            }
            return URL(string: s)
        }
        return nil
    }

    private func goBack() {
        NotificationCenter.default.post(name: .browserWebViewGoBack, object: nil)
    }

    private func goForward() {
        NotificationCenter.default.post(name: .browserWebViewGoForward, object: nil)
    }

    private func reload() {
        NotificationCenter.default.post(name: .browserWebViewReload, object: nil)
    }

    private func saveCurrentPageToOffline() {
        guard let url = selectedTab?.currentURL, canSaveCurrentPage else { return }
        app.saveError = nil
        app.saveJobState = .queued(url)
        app.saveURLToOffline(url)
    }

    private var selectedTabIndex: Int? {
        guard let id = selectedTabID else { return nil }
        return tabs.firstIndex(where: { $0.id == id })
    }

    private var selectedTab: BrowserTab? {
        guard let idx = selectedTabIndex, tabs.indices.contains(idx) else { return nil }
        return tabs[idx]
    }

    private func newTab() {
        let tab = BrowserTab(initialURL: initialURL)
        tabs.append(tab)
        selectedTabID = tab.id
        searchOrURL = initialURL.absoluteString
    }

    private func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if tabs.isEmpty {
            let tab = BrowserTab(initialURL: initialURL)
            tabs = [tab]
            selectedTabID = tab.id
            searchOrURL = initialURL.absoluteString
            return
        }
        if selectedTabID == id {
            selectedTabID = tabs.last?.id
        }
    }

    private func tabLabel(_ tab: BrowserTab) -> String {
        if tab.isLoading { return "Loading..." }
        if !tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tab.title != "New Tab" {
            return tab.title
        }
        return tab.currentURL?.host ?? "New Tab"
    }

    private func binding<Value>(for tabID: UUID, keyPath: WritableKeyPath<BrowserTab, Value>) -> Binding<Value> {
        Binding(
            get: {
                guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else {
                    return BrowserTab(initialURL: initialURL)[keyPath: keyPath]
                }
                return tabs[idx][keyPath: keyPath]
            },
            set: { newValue in
                guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
                tabs[idx][keyPath: keyPath] = newValue
            }
        )
    }
}

extension Notification.Name {
    static let browserWebViewGoBack = Notification.Name("browserWebViewGoBack")
    static let browserWebViewGoForward = Notification.Name("browserWebViewGoForward")
    static let browserWebViewReload = Notification.Name("browserWebViewReload")
}

// MARK: - WKWebView Representable

struct BrowserWebView: NSViewRepresentable {
    @Binding var urlToLoad: URL?
    @Binding var currentURL: URL?
    @Binding var isLoading: Bool
    @Binding var pageTitle: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = WKProcessPool()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        context.coordinator.setupNotifications()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if let url = urlToLoad {
            context.coordinator.pendingURL = nil
            urlToLoad = nil
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentURL: $currentURL, isLoading: $isLoading, pageTitle: $pageTitle)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var currentURL: URL?
        @Binding var isLoading: Bool
        @Binding var pageTitle: String
        weak var webView: WKWebView?
        var pendingURL: URL?

        init(currentURL: Binding<URL?>, isLoading: Binding<Bool>, pageTitle: Binding<String>) {
            _currentURL = currentURL
            _isLoading = isLoading
            _pageTitle = pageTitle
        }

        func setupNotifications() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(goBack),
                name: .browserWebViewGoBack,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(goForward),
                name: .browserWebViewGoForward,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reload),
                name: .browserWebViewReload,
                object: nil
            )
        }

        @objc private func goBack() {
            webView?.goBack()
        }

        @objc private func goForward() {
            webView?.goForward()
        }

        @objc private func reload() {
            webView?.reload()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            pendingURL = webView.url
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            let url = webView.url
            currentURL = url
            pageTitle = webView.title ?? url?.host ?? "New Tab"
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            currentURL = webView.url
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            currentURL = nil
        }
    }
}
