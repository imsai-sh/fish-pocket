import SwiftUI

/// A conversation's browser (S-87): its tabs, which one is in front, and the one the agent works in.
///
/// It is one browser, as on a desktop: the user and the agent see and use the same tabs. The agent
/// lists them, opens, switches and closes them through the browser capability, and its other
/// operations act on the tab it names or, without one, the tab it last used. So a link the user
/// opens in a new tab, or a tab the user brings to the front, does not move the agent elsewhere.
@MainActor
@Observable
final class BrowserModel {
    @MainActor
    @Observable
    final class Tab: Identifiable {
        /// Short and stable while the app runs (`t1`, `t2`…): the agent names tabs by it.
        let id: String
        /// The live page; nil once it was let go to save memory, until it is wanted again.
        fileprivate(set) var page: BrowserPage?
        /// Where a page that was let go (or not loaded yet) is to come back to.
        fileprivate var savedURL: String?
        fileprivate var savedTitle: String?
        /// When it was last in front or used by the agent, to choose which page to let go.
        fileprivate var used = Date()

        fileprivate init(id: String) { self.id = id }

        var url: String? { page?.lastURL ?? savedURL }
        var title: String? { page?.title ?? savedTitle }
        /// It has (or had) a page, rather than being a blank new tab.
        var started: Bool { page?.started == true || savedURL != nil }
    }

    /// A tab as kept across launches.
    struct Saved: Codable, Equatable {
        var url: String
        var title: String?
    }

    private(set) var tabs: [Tab] = []
    private(set) var selectedId: String?
    /// The tabs open when the app last ran, until they are restored or something else is opened.
    private(set) var restorable: [Saved] = []
    /// The tab the agent last worked in: its operations go there unless they name another.
    @ObservationIgnored private(set) var agentTabId: String?
    /// The user opened a blank tab: its address bar takes the keyboard when it shows.
    @ObservationIgnored var focusesAddress = false

    @ObservationIgnored let origin: URL
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private var restorableSelected = 0
    @ObservationIgnored private var nextId = 1

    var selected: Tab? { tabs.first { $0.id == selectedId } }
    /// The address of the tab in front.
    var url: URL? { selected?.url.flatMap(URL.init(string:)) }
    /// Some tab has a page: the chat shows a way back to the browser.
    var hasPages: Bool { tabs.contains(where: \.started) }
    /// The agent is at work in one of the tabs.
    var agentBusy: Bool { tabs.contains { $0.page?.agentBusy == true } }

    func tab(_ id: String) -> Tab? { tabs.first { $0.id == id } }

    // MARK: One per conversation

    /// The conversations' browsers. Observed, so a conversation can show that its browser has a page.
    @MainActor @Observable final class Registry {
        fileprivate(set) var models: [String: BrowserModel] = [:]
    }
    static let registry = Registry()

    /// This conversation's browser if it has one, without making one.
    static func existing(_ sessionId: String) -> BrowserModel? { registry.models[sessionId] }

    /// This conversation's browser, made on first use by the workbench, a link or the agent.
    static func session(_ sessionId: String, origin: URL) -> BrowserModel {
        if let model = registry.models[sessionId] { return model }
        let model = BrowserModel(sessionId: sessionId, origin: origin)
        registry.models[sessionId] = model
        return model
    }

    private init(sessionId: String, origin: URL) {
        self.origin = origin
        storageKey = "dsh.browser.tabs.\(sessionId)"
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: storageKey), let kept = try? JSONDecoder().decode(Kept.self, from: data) {
            restorable = kept.tabs
            restorableSelected = kept.selected
        } else if let last = defaults.string(forKey: "dsh.browser.last.\(sessionId)") {
            // Kept by the one-page browser before tabs.
            restorable = [Saved(url: last, title: nil)]
        }
        let blank = makeTab()
        tabs = [blank]
        selectedId = blank.id
        revive(blank)
    }

    // MARK: Tabs

    /// Each page is a web process of its own: across every conversation, at most this many are live.
    /// The least recently used tab that is not on screen lets its page go and reloads when wanted again.
    private static let livePageLimit = 6
    /// A conversation keeps at most this many tabs; one more closes the least recently used in the back.
    private static let tabLimit = 20

    /// A new tab, in front, opening `url` if there is one.
    @discardableResult
    func newTab(_ url: String? = nil) -> Tab {
        let tab = makeTab()
        tabs.append(tab)
        selectedId = tab.id
        let page = revive(tab)
        if let url { page.go(url) }
        while tabs.count > Self.tabLimit,
              let stale = tabs.filter({ $0.id != selectedId && $0.id != agentTabId && $0.page?.agentBusy != true }).min(by: { $0.used < $1.used }) {
            close(stale)
        }
        save()
        return tab
    }

    /// A link the user tapped: always a tab of its own, so no page is replaced; a blank tab in front takes it.
    func openLink(_ url: String) {
        if let tab = selected, !tab.started, let page = tab.page {
            page.go(url)
        } else {
            newTab(url)
        }
    }

    func select(_ tab: Tab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        selectedId = tab.id
        tab.used = Date()
        revive(tab)
        save()
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.page?.close()
        tab.page = nil
        tabs.remove(at: index)
        if agentTabId == tab.id { agentTabId = nil }
        if tabs.isEmpty {
            // As in Safari, closing the last tab leaves a blank one.
            let blank = makeTab()
            tabs = [blank]
            selectedId = blank.id
            revive(blank)
        } else if selectedId == tab.id {
            select(tabs[min(index, tabs.count - 1)])
        }
        save()
    }

    /// The tab in front has its page, after it was let go to save memory.
    func reviveSelected() {
        if let tab = selected, tab.page == nil { revive(tab) }
    }

    /// Bring back the tabs open when the app last ran. A blank tab in front makes way for them.
    func restore() {
        guard !restorable.isEmpty else { return }
        if tabs.count == 1, let blank = tabs.first, !blank.started {
            blank.page?.close()
            tabs = []
        }
        let restored = restorable.map { saved in
            let tab = makeTab()
            tab.savedURL = saved.url
            tab.savedTitle = saved.title
            return tab
        }
        tabs.append(contentsOf: restored)
        let front = restored[min(max(restorableSelected, 0), restored.count - 1)]
        restorable = []
        // Only the one in front loads now; the others when they are chosen.
        select(front)
    }

    /// The tab's page, made (and sent back to its address) if it was let go.
    @discardableResult
    func revive(_ tab: Tab) -> BrowserPage {
        if let page = tab.page { return page }
        let page = BrowserPage(origin: origin)
        page.changed = { [weak self] in self?.pageChanged() }
        tab.page = page
        tab.used = Date()
        if let url = tab.savedURL { page.go(url) }
        Self.trimLivePages(keeping: page)
        return page
    }

    private func makeTab() -> Tab {
        defer { nextId += 1 }
        return Tab(id: "t\(nextId)")
    }

    /// Every live page of every conversation.
    static var livePages: [BrowserPage] { registry.models.values.flatMap { $0.tabs.compactMap(\.page) } }

    private static func trimLivePages(keeping kept: BrowserPage) {
        while true {
            let live = registry.models.values.flatMap { model in model.tabs.filter { $0.page != nil }.map { (model, $0) } }
            guard live.count > livePageLimit else { return }
            let candidates = live.filter { _, tab in
                guard let page = tab.page else { return false }
                return page !== kept && !page.onScreen && !page.agentBusy
            }
            guard let (model, stale) = candidates.min(by: { $0.1.used < $1.1.used }) else { return }
            model.letGo(stale)
        }
    }

    /// Release the tab's page, keeping where it was.
    private func letGo(_ tab: Tab) {
        guard let page = tab.page else { return }
        tab.savedURL = page.lastURL ?? tab.savedURL
        tab.savedTitle = page.title ?? tab.savedTitle
        page.close()
        tab.page = nil
    }

    // MARK: Kept across launches

    private struct Kept: Codable {
        var tabs: [Saved]
        var selected: Int
    }

    private func pageChanged() {
        // A page opened in this launch replaces the set kept from the last one.
        if !restorable.isEmpty, hasPages { restorable = [] }
        save()
    }

    private func save() {
        let kept = tabs.compactMap { tab in tab.url.map { Saved(url: $0, title: tab.title) } }
        guard !kept.isEmpty else {
            // Nothing opened yet in this launch: the last launch's set stays to be restored.
            if restorable.isEmpty { UserDefaults.standard.removeObject(forKey: storageKey) }
            return
        }
        let front = tabs.filter { $0.url != nil }.firstIndex { $0.id == selectedId } ?? 0
        if let data = try? JSONEncoder().encode(Kept(tabs: kept, selected: front)) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: The agent's tab

    /// Which tab an agent operation goes to: the one it names, else the one it last used. Without
    /// either, `open` takes a blank tab in front or opens a new one, so it never replaces a page the
    /// user is on; the other operations take the tab in front.
    func agentTarget(_ id: String?, opening: Bool) throws -> Tab {
        if let id {
            guard let tab = tab(id) else {
                throw BrowserAgentError("There is no tab '\(id)'. Use `tabs` to see the open ones.")
            }
            return tab
        }
        if let id = agentTabId, let tab = tab(id) { return tab }
        if opening {
            if let tab = selected, !tab.started { return tab }
            return newTab()
        }
        if let tab = selected, tab.started { return tab }
        throw BrowserAgentError("No page is open in this conversation's browser yet. Use `open` with a URL first.")
    }

    /// The agent works in this tab from now on, until it names another.
    func agentUses(_ tab: Tab) {
        agentTabId = tab.id
        tab.used = Date()
    }

    func forgetAgentTab() { agentTabId = nil }
}

/// The tabs of a conversation's browser: switch, open, close.
struct BrowserTabsSheet: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.tabs) { tab in
                    row(tab)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { close(tab) } label: { Label("关闭", systemImage: "xmark") }
                        }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text("\(model.tabs.count) 个标签页"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        model.focusesAddress = true
                        model.newTab()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建标签页")
                }
            }
            .closeButton(action: { dismiss() })
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ tab: BrowserModel.Tab) -> some View {
        let selected = tab.id == model.selectedId
        return HStack(spacing: 12) {
            Button {
                Haptics.select()
                model.select(tab)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.body)
                        .foregroundStyle(selected ? Palette.ink : Palette.secondary)
                        .overlay(alignment: .topTrailing) {
                            // The agent is at work there.
                            if tab.page?.agentBusy == true {
                                Circle().fill(Palette.running).frame(width: 7, height: 7).offset(x: 3, y: -3)
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.title ?? Self.host(tab.url) ?? String(localized: "新标签页"))
                            .font(.body.weight(selected ? .semibold : .regular))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        if let url = tab.url {
                            Text(Self.host(url) ?? url).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button { close(tab) } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(Palette.secondary).hitTarget(36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭标签页")
        }
    }

    private func close(_ tab: BrowserModel.Tab) {
        Haptics.tap()
        withAnimation(.snappy(duration: 0.2)) { model.close(tab) }
    }

    private static func host(_ url: String?) -> String? { FullScreenBrowser.site(url.flatMap(URL.init(string:))) }
}
