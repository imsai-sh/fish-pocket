import SwiftUI
import WebKit

/// The workbench browser (S-87): one WKWebView per conversation, its address, and the last page of the session.
/// There is no proxy and no RPC; the engine runs in this app, so `localhost` reaches a dev server the agent started.
///
/// The agent drives this same page through the browser capability (`BrowserAgent.swift`), so the user can watch it
/// and take over. That is why the page belongs to `session(_:origin:)` rather than to a view: the agent can open one
/// before the user ever looks at the workbench.
@MainActor
@Observable
final class BrowserModel: NSObject {
    var address = ""
    /// The refused address's reason, shown under the bar.
    var addressError: String?
    private(set) var started = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var loading = false
    private(set) var failure: String?
    private(set) var lastURL: String?
    /// What is on screen now, for the bar's menu.
    private(set) var page: URL?
    /// The page on screen came as the site's desktop version, as WebKit settled it.
    private(set) var desktop = false
    /// The agent is in the middle of an operation on this page.
    private(set) var agentBusy = false

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored let origin: URL
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Why the last load failed, as WebKit said it, for the agent; `failure` is the user's sentence.
    @ObservationIgnored private(set) var loadFailure: NSError?
    /// The agent's operations, one after another: two at once would read a page the other is changing.
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// The agent at work on this page, drawn over it in the workbench.
    @ObservationIgnored let presence = BrowserPresence()

    // MARK: One per conversation

    /// The open conversations' browsers. A few at most: each page is a web process of its own.
    /// Observed, so a conversation can show that its browser has a page.
    @MainActor @Observable final class Registry {
        fileprivate(set) var models: [String: BrowserModel] = [:]
    }
    static let registry = Registry()
    private static var open: [String: BrowserModel] {
        get { registry.models }
        set { registry.models = newValue }
    }

    /// This conversation's browser if it has one, without making one.
    static func existing(_ sessionId: String) -> BrowserModel? { registry.models[sessionId] }
    private static var recent: [String] = []
    private static let kept = 3

    /// This conversation's browser, made on first use by either the workbench or the agent.
    static func session(_ sessionId: String, origin: URL) -> BrowserModel {
        recent.removeAll { $0 == sessionId }
        recent.append(sessionId)
        if let model = open[sessionId] { return model }
        let model = BrowserModel(sessionId: sessionId, origin: origin)
        open[sessionId] = model
        // The least recently used page that is not on screen goes; its address stays for "恢复页面".
        while open.count > kept, let stale = recent.first(where: { open[$0]?.onScreen == false && $0 != sessionId }) {
            recent.removeAll { $0 == stale }
            open.removeValue(forKey: stale)?.close()
        }
        return model
    }

    /// Every conversation's browser shares one store of its own, kept across launches, so a site signed in
    /// to once stays signed in, for the user and for the agent. It is apart from the default store, where the
    /// engine's web view keeps its session cookie, and from Safari, which no app can read.
    private static let store = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "8E4C2D1A-5B7F-4A3E-9C6D-2F1B0A9E7D45")!)

    /// Sign out of every site: cookies, storage and caches of all the conversations' browsers.
    static func clearWebsiteData() async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        for model in open.values where model.webView.url != nil { model.webView.reload() }
    }

    private init(sessionId: String, origin: URL) {
        storageKey = "dsh.browser.last.\(sessionId)"
        self.origin = origin
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.store
        configuration.allowsInlineMediaPlayback = true
        // As in Safari, a pinch zooms every page, including one that asks not to be zoomed
        // (`user-scalable=no`, `maximum-scale=1`), as most mobile sites do.
        configuration.ignoresViewportScaleLimits = true
        if let script = Self.controllerScript { configuration.userContentController.addUserScript(script) }
        configuration.userContentController.add(
            BrowserPresence.Listener(presence), contentWorld: Self.agentWorld, name: BrowserPresence.Listener.name)
        configuration.userContentController.addUserScript(Self.desktopViewport)
        webView = WKWebView(frame: .zero, configuration: configuration)
        lastURL = UserDefaults.standard.string(forKey: storageKey)
        super.init()
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.loading = view.isLoading } },
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.navigated(to: view.url) } },
        ]
    }

    private func navigated(to url: URL?) {
        guard let url, url.scheme == "http" || url.scheme == "https" else { return }
        page = url
        address = url.absoluteString
        lastURL = url.absoluteString
        UserDefaults.standard.set(url.absoluteString, forKey: storageKey)
    }

    /// Open what the bar holds, or say why not.
    func go(_ input: String? = nil) {
        switch Self.parse(input ?? address, applicationOrigin: origin) {
        case .success(let url):
            addressError = nil
            failure = nil
            loadFailure = nil
            started = true
            address = url.absoluteString
            webView.load(URLRequest(url: url))
        case .failure(let refusal):
            addressError = refusal.message
        }
    }

    func reload() {
        failure = nil
        if webView.url == nil, let lastURL { go(lastURL) } else if loading { webView.stopLoading() } else { webView.reload() }
    }

    /// Run the agent's operations in the order they came.
    func serially<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            agentBusy = true
            defer { agentBusy = false }
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// In a SwiftUI page now, rather than parked or nowhere.
    private var onScreen: Bool { webView.window != nil && webView.superview !== webView.window }

    /// A page off screen still has to lay out and run its scripts for the agent to read it, which WebKit does
    /// only for a view in a window. So until the workbench shows it, it waits behind the window's content, the
    /// size of the window. The workbench takes it from here by adding it to its own page.
    func attachIfDetached() {
        guard webView.window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        webView.frame = window.bounds
        window.insertSubview(webView, at: 0)
    }

    private func close() {
        presence.finish()
        webView.stopLoading()
        if webView.superview === webView.window { webView.removeFromSuperview() }
    }

    /// What page-agent's effects on the page should be (`entry.js`'s `presence`).
    struct PageEffects: Equatable {
        var shown: Bool
        var action: String?
        var done: Bool
    }

    /// The effects as last asked for; a page that loads afresh gets them again.
    @ObservationIgnored private var effects = PageEffects(shown: false, action: nil, done: true)

    func showEffects(_ effects: PageEffects) {
        self.effects = effects
        sendEffects()
    }

    fileprivate func sendEffects() {
        guard webView.url != nil else { return }
        let state: [String: Any] = ["shown": effects.shown, "action": effects.action ?? NSNull(), "done": effects.done]
        webView.callAsyncJavaScript(
            "await globalThis.__dshBrowser?.presence(state)", arguments: ["state": state], in: nil, in: Self.agentWorld
        ) { _ in }
    }

    // MARK: Desktop or mobile version

    /// The version asked for by site, as Safari's 「请求桌面网站」: kept across launches and shared by every
    /// conversation's browser, the agent's too. A site with no choice gets WebKit's own (mobile on a phone).
    private static let contentModesKey = "dsh.browser.contentModes"

    /// The name a choice is kept under: `www.` and `m.` are one site dressed two ways, and a site with a
    /// desktop and a mobile host often sends a browser from one to the other.
    static func site(of url: URL) -> String? {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        for prefix in ["www.", "m.", "mobile.", "wap."] where host.hasPrefix(prefix) && host.split(separator: ".").count > 2 {
            host.removeFirst(prefix.count)
            break
        }
        return host
    }

    /// The choice for this address: its site's, or that of a site it is under.
    static func asksForDesktop(_ url: URL) -> Bool? {
        guard let site = site(of: url) else { return nil }
        let modes = UserDefaults.standard.dictionary(forKey: contentModesKey) as? [String: Bool] ?? [:]
        // A one-word host such as `localhost` is a site of its own.
        if let desktop = modes[site] { return desktop }
        // A domain's choice holds under it too (`docs.example.com` under `example.com`). An address has
        // nothing above it: `127.0.0.1` is not under `0.0.1`.
        guard !isAddress(site) else { return nil }
        var labels = site.split(separator: ".").dropFirst()
        while labels.count >= 2 {
            if let desktop = modes[labels.joined(separator: ".")] { return desktop }
            labels.removeFirst()
        }
        return nil
    }

    /// An IP address rather than a name: IPv6 has colons, IPv4 is all numbers.
    private static func isAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    static func setDesktop(_ desktop: Bool, for url: URL) {
        guard let site = site(of: url) else { return }
        var modes = UserDefaults.standard.dictionary(forKey: contentModesKey) as? [String: Bool] ?? [:]
        modes[site] = desktop
        UserDefaults.standard.set(modes, forKey: contentModesKey)
    }

    /// On a phone, WebKit's desktop version sends a Mac's user agent but still lays the page out as wide as
    /// the screen when the page asks for `width=device-width`, so a desktop layout spills off the side. As
    /// Safari does, lay it out as wide as a small laptop and let it zoom out to fit; a pinch zooms back in.
    /// Only for a desktop version on a narrow screen: an iPad's own desktop pages are left alone.
    static let desktopViewport = WKUserScript(source: """
    (() => {
      if (!/Macintosh/.test(navigator.userAgent) || screen.width >= 1024) return;
      const content = 'width=1024';
      const fix = () => {
        const metas = document.querySelectorAll('meta[name="viewport" i]');
        if (metas.length === 0) {
          const meta = document.createElement('meta');
          meta.name = 'viewport';
          meta.content = content;
          (document.head || document.documentElement).appendChild(meta);
        }
        for (const meta of metas) if (meta.content !== content) meta.content = content;
      };
      fix();
      // A script-built page adds or rewrites its viewport later; only the head is watched.
      const watch = () => {
        fix();
        if (document.head) new MutationObserver(fix).observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['content'] });
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watch, { once: true }); else watch();
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: agentWorld)

    /// Switch the page on screen to the other version and load it again.
    func setDesktop(_ desktop: Bool) {
        guard let url = page else { return }
        Self.setDesktop(desktop, for: url)
        failure = nil
        loadFailure = nil
        webView.reload()
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }

    fileprivate func failed(_ error: Error) {
        let error = error as NSError
        // A newer navigation replaced this one.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        loadFailure = error
        failure = String(localized: "页面加载失败 (\(error.code)): \(error.localizedDescription)")
    }

    fileprivate func clearFailure() {
        failure = nil
        loadFailure = nil
    }

    enum Refusal: Error {
        case empty, invalid, credentials, applicationOrigin, unsupportedScheme

        var message: String {
            switch self {
            case .empty: String(localized: "请输入地址。")
            case .invalid: String(localized: "这个地址无效或过长。")
            case .credentials: String(localized: "地址不能包含用户名或密码。")
            case .applicationOrigin: String(localized: "不能在嵌入浏览器中打开 DSH 应用自身。")
            case .unsupportedScheme: String(localized: "只支持 HTTP 和 HTTPS 地址；本地文件请使用文档预览。")
            }
        }
    }

    /// `parseBrowserAddress`, with one change: a bare loopback address means `http`
    /// here, because that is what a dev server on this device speaks.
    static func parse(_ input: String, applicationOrigin: URL) -> Result<URL, Refusal> {
        let trimmed = input.trimmed
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed.count > 16384 { return .failure(.invalid) }
        let hasScheme = trimmed.range(of: #"^[A-Za-z][A-Za-z\d+.-]*:(?!\d+(?:[/?#]|$))"#, options: .regularExpression) != nil
        let candidate = hasScheme ? trimmed : (isLoopback(trimmed) ? "http://" : "https://") + trimmed
        guard let url = URL(string: candidate), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.invalid) }
        if components.user != nil || components.password != nil { return .failure(.credentials) }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme) }
        guard let host = url.host(), !host.isEmpty else { return .failure(.invalid) }
        if sameOrigin(url, applicationOrigin) { return .failure(.applicationOrigin) }
        return .success(url)
    }

    private static func isLoopback(_ address: String) -> Bool {
        let host = address.prefix { !"/?#".contains($0) }
        return host == "localhost" || host.hasPrefix("localhost:") || host.hasPrefix("127.") || host.hasPrefix("0.0.0.0") || host.hasPrefix("[::1]")
    }

    private static func sameOrigin(_ url: URL, _ origin: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil) }
        let hosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1"]
        let sameHost = url.host() == origin.host() || (hosts.contains(url.host() ?? "") && hosts.contains(origin.host() ?? ""))
        return sameHost && port(url) == port(origin)
    }
}

extension BrowserModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        clearFailure()
        desktop = navigation.effectiveContentMode == .desktop
    }

    /// Each page goes out as the version its site was asked for, which is what the server sees in the
    /// user agent and how wide the page lays out. Frames inside it follow the page.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url,
           let desktop = Self.asksForDesktop(url) {
            preferences.preferredContentMode = desktop ? .desktop : .mobile
        }
        decisionHandler(.allow, preferences)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sendEffects() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    /// `target=_blank` and `window.open` stay in the one page this bar controls.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

struct WorkbenchBrowser: View {
    @Bindable var model: BrowserModel
    @FocusState private var editing: Bool
    @State private var confirmingClear = false

    /// Where dev servers usually listen; the agent's own port goes in the bar.
    private static let commonPorts = [3000, 5173, 8000, 8080]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                BrowserWebView(webView: model.webView)
                    .overlay { BrowserAgentOverlay(model: model) }
                    .opacity(model.started ? 1 : 0)
                if !model.started { start }
            }
            if let error = model.addressError {
                notice(error)
            } else if let failure = model.failure {
                notice(failure)
            }
            bar
        }
        .background(Palette.background)
        // On the page rather than the menu: a dialog hung on a Menu can fail to present.
        .confirmationDialog("清除网站数据？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { Task { await BrowserModel.clearWebsiteData() } }
        } message: {
            Text("所有会话的浏览器都会退出登录，Cookie 和网站存储一并删除。")
        }
    }

    /// Under the thumb, as in Safari; it rides up on the keyboard while typing an address.
    private var bar: some View {
        HStack(spacing: 0) {
            button("chevron.backward", "后退", enabled: model.canGoBack) { model.presence.dismiss(); model.back() }
            button("chevron.forward", "前进", enabled: model.canGoForward) { model.presence.dismiss(); model.forward() }
            HStack(spacing: 6) {
                TextField("输入 HTTP(S) 地址", text: $model.address)
                    .font(.subheadline)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($editing)
                    .onSubmit { model.presence.dismiss(); model.go() }
                if model.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Palette.bubble, in: Capsule())
            .padding(.horizontal, 4)
            more
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var more: some View {
        Menu {
            Button { model.presence.dismiss(); model.reload() } label: {
                Label(model.loading ? "停止" : "刷新", systemImage: model.loading ? "xmark" : "arrow.clockwise")
            }
            .disabled(!model.started && model.lastURL == nil)
            Button { model.setDesktop(!model.desktop) } label: {
                if model.desktop {
                    Label("请求移动版网站", systemImage: "iphone")
                } else {
                    Label("请求电脑版网站", systemImage: "desktopcomputer")
                }
            }
            .disabled(model.page == nil)
            Button {
                if let url = model.page { UIApplication.shared.open(url) }
            } label: {
                Label("在系统浏览器中打开", systemImage: "safari")
            }
            .disabled(model.page == nil)
            if let url = model.page { ShareLink("分享", item: url) }
            Divider()
            Button(role: .destructive) { confirmingClear = true } label: {
                Label("清除网站数据", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
    }

    private func button(_ icon: String, _ label: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(enabled ? Palette.ink : Palette.faint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.removed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
    }

    /// Before the first page: where the session left off, and the local ports.
    private var start: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let last = model.lastURL {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("上次打开").font(.footnote).foregroundStyle(Palette.secondary)
                        Text(last).font(.callout).lineLimit(2).truncationMode(.middle)
                        Button("恢复页面") { model.go(last) }.buttonStyle(.capsule(height: 44, fill: false))
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("本机服务").font(.footnote).foregroundStyle(Palette.secondary)
                    Text("智能体在这台设备上启动的开发服务器，用 localhost 打开。").font(.footnote).foregroundStyle(Palette.secondary)
                    HStack(spacing: 8) {
                        ForEach(Self.commonPorts, id: \.self) { port in
                            Button(":\(String(port))") { model.go("localhost:\(port)") }
                                .buttonStyle(.capsule(.secondary, height: 44, fill: false))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// The browser opened from the chat: the page alone, full screen, without the workbench's other tabs.
struct FullScreenBrowser: View {
    let model: BrowserModel
    let close: () -> Void

    var body: some View {
        NavigationStack {
            WorkbenchBrowser(model: model)
                .navigationTitle(Self.site(model.page) ?? String(localized: "浏览器"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .closeButton(action: close)
        }
    }

    /// `www.` says nothing; the rest of the host is the site.
    static func site(_ url: URL?) -> String? {
        guard let host = url?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A conversation has one web view, and it can be on screen in one place at a time: the workbench, or
/// the browser opened full screen from the chat. The holder that comes into a window takes it; the one
/// that leaves gives it back to another still on screen, so the workbench has its page again.
private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> Holder { Holder(webView) }
    func updateUIView(_ view: Holder, context: Context) {}

    final class Holder: UIView {
        let webView: WKWebView
        private static let all = NSHashTable<Holder>.weakObjects()

        init(_ webView: WKWebView) {
            self.webView = webView
            super.init(frame: .zero)
            Self.all.add(self)
            adopt()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                adopt()
            } else if webView.superview === self,
                      let other = Self.all.allObjects.last(where: { $0 !== self && $0.webView === webView && $0.window != nil }) {
                other.adopt()
            }
        }

        /// Whatever size the page was in elsewhere, here it is this holder's.
        override func layoutSubviews() {
            super.layoutSubviews()
            if webView.superview === self, webView.frame != bounds { webView.frame = bounds }
        }

        private func adopt() {
            guard webView.superview !== self else { return }
            webView.removeFromSuperview()
            webView.frame = bounds
            addSubview(webView)
            setNeedsLayout()
        }
    }
}
