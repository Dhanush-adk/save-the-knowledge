//
//  WebSearchView.swift
//  KnowledgeCache
//
//  Browse the web (URL navigation only). "Save to offline" stores the
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
    @State private var browserNotice: String?
    @FocusState private var isSearchFocused: Bool
    private let starterURLs: [String] = [
        "https://www.google.com",
        "https://www.mozilla.org",
        "https://news.ycombinator.com",
        "https://www.apple.com/newsroom",
        "https://en.wikipedia.org/wiki/Artificial_intelligence",
        "https://developer.apple.com/documentation"
    ]

    private var initialURL: URL {
        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <title>Save the Knowledge Browser</title>
            <style>
              body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; background: #ffffff; color: #111827; }
              .wrap { max-width: 760px; margin: 10vh auto; padding: 24px; text-align: center; }
              h1 { margin: 0 0 10px; font-size: 2rem; }
              p { color: #4b5563; line-height: 1.45; }
              .box { margin-top: 22px; padding: 16px; border: 1px solid #e5e7eb; border-radius: 10px; background: #f9fafb; }
            </style>
          </head>
          <body>
            <div class="wrap">
              <h1>Save the Knowledge Browser</h1>
              <p>Enter a URL in the address bar to browse and save pages for offline use.</p>
              <div class="box">
                You can search the web directly from the address bar.<br/>
                Save useful pages, then use the <b>Search</b> tab to ask questions from your offline knowledge base.
              </div>
            </div>
          </body>
        </html>
        """
        let encoded = Data(html.utf8).base64EncodedString()
        return URL(string: "data:text/html;base64,\(encoded)") ?? URL(string: "about:blank")!
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            toolbar
            if shouldShowWebOnboarding {
                webOnboardingCard
            }
            if let notice = browserNotice, !notice.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.08))
            }
            if app.isSaveInProgress || app.saveError != nil || saveSuccessVisible || app.saveJobState != .idle {
                saveStatusBanner
            }
            Divider()
            ZStack {
                ForEach(tabs) { tab in
                    BrowserWebView(
                        tabId: tab.id,
                        urlToLoad: binding(for: tab.id, keyPath: \.pendingLoadURL),
                        currentURL: binding(for: tab.id, keyPath: \.currentURL),
                        isLoading: binding(for: tab.id, keyPath: \.isLoading),
                        pageTitle: binding(for: tab.id, keyPath: \.title),
                        onNavigationStarted: { url in
                            app.browserNavigationStarted(tabId: tab.id, url: url)
                        },
                        onNavigationFinished: { url in
                            app.browserNavigationFinished(tabId: tab.id, url: url)
                        },
                        onScrollChanged: { scrollPct in
                            app.browserScrollUpdated(tabId: tab.id, scrollPct: scrollPct)
                        }
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
                searchOrURL = ""
            }
        }
        .onChange(of: selectedTabID) { _, newID in
            guard let id = newID, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
            searchOrURL = displayAddress(for: tabs[idx].currentURL)
        }
        .onChange(of: tabs) { _, _ in
            guard let tab = selectedTab else { return }
            searchOrURL = displayAddress(for: tab.currentURL)
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
                TextField("Paste URL (example.com/article)", text: $searchOrURL)
                    .accessibilityLabel("Address bar")
                    .textFieldStyle(.plain)
                    .onSubmit { loadSearchOrURL() }
                    .focused($isSearchFocused)
                    .help("Web tab accepts URLs only. Example: https://example.com/page")
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
        return url.host != nil
    }

    private var shouldShowWebOnboarding: Bool {
        guard let url = selectedTab?.currentURL else { return true }
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "data" || scheme == "about"
    }

    private var webOnboardingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start with a URL")
                .font(.headline)
            Text("This tab is for browsing pages by URL. Paste a page link first, open it, then click Save to offline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("1. Paste a URL in the address bar")
                Text("2. Open the page")
                Text("3. Click Save to offline")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Try one of these")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(starterURLs, id: \.self) { url in
                        Button(action: { openStarterURL(url) }) {
                            Text(url.replacingOccurrences(of: "https://", with: ""))
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(url)")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
    }

    private func loadSearchOrURL() {
        let input = searchOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard let idx = selectedTabIndex else { return }
        if let url = parseAsURL(input) {
            tabs[idx].pendingLoadURL = url
            tabs[idx].currentURL = url
            browserNotice = nil
        } else {
            browserNotice = "Web tab takes URLs only. Paste a full URL such as https://example.com/article"
        }
    }

    private func openStarterURL(_ raw: String) {
        searchOrURL = raw
        loadSearchOrURL()
    }

    private func parseAsURL(_ input: String) -> URL? {
        if input.contains(".") && !input.contains(" ") {
            var s = input
            if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
                s = "https://" + s
            }
            guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), (scheme == "http" || scheme == "https") else {
                return nil
            }
            return u
        }
        return nil
    }

    private func displayAddress(for url: URL?) -> String {
        guard let url = url else { return "" }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "data" || scheme == "about" {
            return ""
        }
        return url.absoluteString
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
        searchOrURL = ""
    }

    private func closeTab(_ id: UUID) {
        app.browserTabClosed(tabId: id)
        tabs.removeAll { $0.id == id }
        if tabs.isEmpty {
            let tab = BrowserTab(initialURL: initialURL)
            tabs = [tab]
            selectedTabID = tab.id
            searchOrURL = ""
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
        if tab.currentURL?.scheme == "data" || tab.currentURL?.scheme == "about" {
            return "Start"
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
    let tabId: UUID
    @Binding var urlToLoad: URL?
    @Binding var currentURL: URL?
    @Binding var isLoading: Bool
    @Binding var pageTitle: String
    let onNavigationStarted: (URL) -> Void
    let onNavigationFinished: (URL) -> Void
    let onScrollChanged: (Double) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = WKProcessPool()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.configuration.userContentController.add(context.coordinator, name: "kcScroll")
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        context.coordinator.setupNotifications()
        context.coordinator.installScrollObserverScript(in: webView)
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
        Coordinator(
            tabId: tabId,
            currentURL: $currentURL,
            isLoading: $isLoading,
            pageTitle: $pageTitle,
            onNavigationStarted: onNavigationStarted,
            onNavigationFinished: onNavigationFinished,
            onScrollChanged: onScrollChanged
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let tabId: UUID
        @Binding var currentURL: URL?
        @Binding var isLoading: Bool
        @Binding var pageTitle: String
        let onNavigationStarted: (URL) -> Void
        let onNavigationFinished: (URL) -> Void
        let onScrollChanged: (Double) -> Void
        weak var webView: WKWebView?
        var pendingURL: URL?

        init(
            tabId: UUID,
            currentURL: Binding<URL?>,
            isLoading: Binding<Bool>,
            pageTitle: Binding<String>,
            onNavigationStarted: @escaping (URL) -> Void,
            onNavigationFinished: @escaping (URL) -> Void,
            onScrollChanged: @escaping (Double) -> Void
        ) {
            self.tabId = tabId
            _currentURL = currentURL
            _isLoading = isLoading
            _pageTitle = pageTitle
            self.onNavigationStarted = onNavigationStarted
            self.onNavigationFinished = onNavigationFinished
            self.onScrollChanged = onScrollChanged
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
            if let url = webView.url {
                onNavigationStarted(url)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            let url = webView.url
            currentURL = url
            pageTitle = webView.title ?? url?.host ?? "New Tab"
            if let url {
                onNavigationFinished(url)
            }
            injectCurrentScrollPosition(webView: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            currentURL = webView.url
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            currentURL = nil
        }

        func installScrollObserverScript(in webView: WKWebView) {
            let source = """
            if (!window.__kcScrollObserver) {
              window.__kcScrollObserver = true;
              window.addEventListener('scroll', function () {
                var doc = document.documentElement || document.body;
                var max = Math.max(1, doc.scrollHeight - window.innerHeight);
                var pct = Math.max(0, Math.min(100, (window.scrollY / max) * 100));
                window.webkit.messageHandlers.kcScroll.postMessage(pct);
              }, { passive: true });
            }
            """
            let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            webView.configuration.userContentController.addUserScript(script)
        }

        private func injectCurrentScrollPosition(webView: WKWebView) {
            let source = """
            (function() {
              var doc = document.documentElement || document.body;
              var max = Math.max(1, doc.scrollHeight - window.innerHeight);
              var pct = Math.max(0, Math.min(100, (window.scrollY / max) * 100));
              window.webkit.messageHandlers.kcScroll.postMessage(pct);
            })();
            """
            webView.evaluateJavaScript(source, completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "kcScroll" else { return }
            if let pct = message.body as? Double {
                onScrollChanged(pct)
            } else if let pct = message.body as? NSNumber {
                onScrollChanged(pct.doubleValue)
            }
        }
    }
}
