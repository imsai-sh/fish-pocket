import StoreKit
import SwiftUI

/// The root. From iOS 18 the system's adaptable tab bar in every width: 会话, Bot, 应用, 探索 and 设置,
/// at the bottom on a phone, at the top or as a sidebar where there is room (iPad, iPhone Duo open).
/// The 会话 tab pushes a conversation over its list where it is narrow and keeps one beside it where it
/// is wide. On an iPhone before iOS 18 the same tabs, on the tab bar of that time (always at the
/// bottom). On an iPad before iOS 18 the session list is the split view's sidebar beside a
/// conversation, always (with nothing selected a blank session opens), and where the window is
/// narrow a drawer that slides in from the left.
struct MainView: View {
    /// The phone's tabs.
    enum HomeTab: Hashable { case sessions, bot, explore }

    enum Sheet: String, Identifiable { case settings, plugins, store, schedules, signIn, cordis, share, watch, capabilities, connectors, phoneControl, remote, fishPocket, deepSeekAccount, miniApps, imageGen, shortcuts; var id: String { rawValue } }

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @AppStorage("dsh.currentWorkspace") private var workspaceId = ""
    @State private var selection: String?
    @State private var sheet: Sheet?
    /// In regular width the plugin store takes the conversation's place beside the sidebar.
    @State private var storeOpen = false
    @State private var webOpen = false
    /// The Bot pages take the conversation's place (the drawer's Bot card opens them).
    @State private var botOpen = false
    @State private var botPath: [BotRoute] = []
    /// The sidebar, in regular width.
    @State private var sidebar = NavigationSplitViewVisibility.all
    @State private var windowWidth: CGFloat = 0
    /// Where this window's page in front has its composer, for the notices above it.
    @State private var docks = BottomDocks()
    /// The window's width as the app left the screen: the split view keeps it while out of sight (`split`).
    @State private var widthOnLeaving: CGFloat?
    @State private var searchRequest = 0
    @State private var drawerOpen = false
    @State private var tab = HomeTab.sessions
    /// The 会话 tab's stack: the conversation on screen (`selection`) on top of the list.
    @State private var sessionsPath: [DrawerView.Route]
    /// The 探索 tab's stack: the plugin store is pushed on it when something asks for it.
    @State private var explorePath: [ExploreTabView.Route] = []
    /// The 会话 tab's own split view, where it is wide: the list can make way for the workbench.
    @State private var sessionsColumns = NavigationSplitViewVisibility.all
    /// The Bot tab's, as the 会话 tab's: the Bot list beside the chat.
    @State private var botColumns = NavigationSplitViewVisibility.all
    @State private var drag: CGFloat = 0
    /// The way a drag on the shell set off, fixed by its first move; nil between drags.
    /// A plain reference filled by the drawer's rows.
    @State private var rowFrames = DrawerRowFrames()
    /// The tab bar's badges, as `HomeBadgeCounter` counts them.
    @State private var badges = HomeBadges()
    @State private var creating = false
    @State private var onboarding: Onboarding?
    /// 「添加 API Key」 was chosen in the sign-in sheet: its key editor follows once that sheet is gone.
    @State private var keyEditorRef: String?
    /// 「Fish Pocket 账号」 was chosen in the sign-in sheet: its page follows once that sheet is gone.
    @State private var fishPocketAfterOnboarding = false
    /// The ask for a rating or a share (`SupportPrompt`'s `.support`).
    @State private var supportDialog = false
    /// 「新功能」 after an update (`WhatsNew`).
    @State private var whatsNew: WhatsNew.Release?
    /// What the launch screen's repair did to get the engine up (NodeEngine.takeRecoveryReport).
    @State private var recovered: [RecoveryState.Action]?
    /// It was shown: no update toast on top of it this time.
    @State private var newsShown = false
    /// 「在电脑上新建会话」, once whatever sheet asked for it has gone.
    @State private var remoteTarget: RemoteSessionTarget?
    /// The launch has gone back to the page the app was last on (`place`); from then on the page
    /// in front is kept for the next launch. A window opened on a session stays on it.
    @State private var placeRestored: Bool
    /// The launch went back to a Bot page: the blank conversation made under it does not take its place.
    @State private var launchedUnderBot = false

    /// A `fishpocket://` link this window received (`RootView`), until it is followed.
    @Binding private var link: LinkRequest?

    /// `session`: the one this window opened on, when it opened on one.
    init(session: String? = nil, link: Binding<LinkRequest?> = .constant(nil)) {
        _selection = State(initialValue: session)
        _sessionsPath = State(initialValue: session.map { [.session($0)] } ?? [])
        _placeRestored = State(initialValue: session != nil)
        _link = link
    }

    private static let placeKey = "dsh.lastPlace"

    /// The page in front, as it is kept for the next launch: a conversation, the Bot list, a
    /// Bot's chat or a group.
    private var place: String? {
        // On the tab bar only 会话 and Bot are kept: from the other tabs the next launch goes back
        // to whichever of the two was last in front.
        if usesTabs, tab != .sessions, tab != .bot { return nil }
        // On the tab bar the list with nothing pushed is a place too: the next launch stays there.
        guard botOpen else { return selection.map { "session:\($0)" } ?? (usesTabs ? "sessions" : nil) }
        switch botPath.last {
        case .bot(let id)?: return "bot:\(id)"
        case .room(let id)?: return "room:\(id)"
        case nil: return "bots"
        }
    }

    /// Back to the page the app was last on, when it is still there; a link or a notification
    /// that opened the app has already picked its own.
    private func restorePlace() {
        guard selection == nil, let kept = UserDefaults.standard.string(forKey: Self.placeKey) else { return }
        let parts = kept.split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "session":
            // A session on a computer is taken on trust while signed in: its page says so if it has gone.
            // A Bot's own session is its chat's, not a conversation to put back.
            if RemoteStore.sessionId(of: id) != nil ? app.remote.signedIn : app.workspace(of: id).map({ !isTeamWorkspace($0) }) == true && !app.isArchived(id) { selection = id }
        case "bot": openBots([.bot(id)])
        case "room": openBots([.room(id)])
        case "bots": openBots([])
        default: break
        }
    }

    private func openBots(_ path: [BotRoute]) {
        launchedUnderBot = true
        botOpen = true
        if usesTabs { tab = .bot }
        botPath = path
    }

    /// The credential sheets (`settings.onboarding`'s steps). Unlike the web they never open by
    /// themselves at launch: the interface comes first, and a message sent with nothing to answer
    /// it asks for them (`SessionModel`), as do the sign-in buttons.
    enum Onboarding: Identifiable {
        case signIn(ref: String, autoStart: Bool = false)
        case key(ref: String)
        var id: String {
            switch self {
            case .signIn: "sign-in"
            case .key: "key"
            }
        }
    }

    /// Where a new conversation goes: the current workspace, else the first-use one, never the Bot
    /// team's, which holds the Bots' sessions alone (a blank one there would be reused: a Bot's chat).
    private var workspace: Workspace? {
        let usable = app.workspaces.filter { !isTeamWorkspace($0) }
        return usable.first { $0.id == workspaceId } ?? usable.first { $0.title == "default-workspace" } ?? usable.first ?? app.workspaces.first
    }

    /// The Bot team's workspace: by the team's word once it answers, before that (the launch races the
    /// Bot plugin) by ds-bot's default folder. The engine lists it before the first-use workspace.
    private func isTeamWorkspace(_ workspace: Workspace) -> Bool {
        workspace.id == app.botTeam.teamWorkspaceId || workspace.path.hasSuffix("/.dsh/bot/workspace")
    }

    /// The workspace a session shown here belongs to becomes the current one; the Bot team's never does.
    private func remember(workspaceOf id: String) {
        if let owner = app.workspace(of: id), !isTeamWorkspace(owner) { workspaceId = owner.id }
    }

    /// A button of the support dialog: the ask is answered for good.
    private func settleSupport(then action: () -> Void) {
        Haptics.tap()
        SupportPrompt.settle()
        supportDialog = false
        action()
    }

    /// The width the layout is made for: the size class, as it was last seen on screen. Leaving the
    /// screen, iOS draws the app at its other width for the app switcher's snapshot and then back
    /// (iPhone Duo open: folded, then open again). Following that would make the layout over twice
    /// out of sight, and whatever a page had presented (a file's preview) would be gone, or on a
    /// device be left standing empty.
    @State private var settledWidth: UserInterfaceSizeClass?
    @State private var windowCommandsBox = WindowCommands.Box()
    @State private var openSessionBox = OpenSessionAction.Box()
    private var layoutWidth: UserInterfaceSizeClass? { settledWidth ?? sizeClass }

    /// Announcements are made once, so never under a sheet.
    private var canAnnounce: Bool {
        scenePhase == .active && onboarding == nil && sheet == nil && whatsNew == nil
    }

    /// The width's own layout, with the way into the plugin store.
    private var layout: some View {
        Group {
            if #available(iOS 18.0, *) {
                tabLayout
            } else if usesTabs {
                phoneTabLayout
            } else if layoutWidth == .regular {
                split
            } else {
                drawerLayout
            }
        }
        // Counted outside this body. Counted here, every change to the session list or to what the
        // Bots are doing would redraw this view, and with it the list and the conversation it builds.
        .background { HomeBadgeCounter(badges: $badges) }
        // The drawer and the Bot pages, which have no way to the store themselves.
        .onChange(of: app.pluginStoreRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.pluginStoreRequest = nil
            openPlugins()
        }
        .onChange(of: app.webRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.webRequest = nil
            webOpen = true
        }
        .onChange(of: app.botTeam.openRequest?.token) { _, token in
            guard token != nil, let request = app.botTeam.openRequest else { return }
            app.botTeam.openRequest = nil
            sheet = nil
            storeOpen = false
            botOpen = true
            if usesTabs { tab = .bot }
            let pages = request.route.map { route in request.push && botPath.last != route ? botPath + [route] : [route] } ?? []
            // Before iOS 18 the stack in the split view's detail does not follow a path changed in
            // here, while the views are being updated: the page on screen stays as it is (a chat
            // shared to with the Bot list open never showed, and the next row tapped was pushed
            // over it). Changed a moment later, it does.
            if #available(iOS 18.0, *) { botPath = pages } else { Task { botPath = pages } }
            setDrawer(false)
        }
        .onChange(of: app.remoteRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.remoteRequest = nil
            setDrawer(false)
            sheet = .remote
        }
        // Asked for from the sidebar, a conversation or a page inside a sheet: that sheet goes first.
        .onChange(of: app.remoteSessionRequest) { _, request in
            guard let request, scenePhase != .background else { return }
            app.remoteSessionRequest = nil
            setDrawer(false)
            let wait = sheet != nil
            sheet = nil
            Task {
                if wait { try? await Task.sleep(for: .milliseconds(450)) }
                remoteTarget = request
            }
        }
        .sheet(item: $remoteTarget) { RemoteNewSessionSheet(target: $0).sheetNotices() }
        // Signed out of remote control (or the server ended it): its conversation has nothing to show.
        .onChange(of: app.remote.signedIn) { _, signedIn in
            if !signedIn, RemoteStore.sessionId(of: selection) != nil { selection = nil }
        }
        // Its computer was taken off the account: the same.
        .onChange(of: app.remote.departed) { _, gone in
            if let id = RemoteStore.sessionId(of: selection), gone.contains(id) { selection = nil }
        }
        .onChange(of: app.connectorsRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.connectorsRequest = nil
            sheet = .connectors
        }
        .onChange(of: app.phoneControlRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.phoneControlRequest = nil
            sheet = .phoneControl
        }
        .fullScreenCover(isPresented: $webOpen) { WebFallbackView() }
        // The Live Activity and the widgets; a cold launch keeps the link until this view is up.
        .onChange(of: link?.token, initial: true) {
            guard let request = link else { return }
            link = nil
            Task { await follow(request.link) }
        }
        .onChange(of: workspaceId) { WidgetSnapshotWriter.shared.refresh() }
        .onAppear { settledWidth = sizeClass }
        .onChange(of: sizeClass) { _, size in
            if scenePhase == .active { settle(size) }
        }
        // On the tab bar the Bot pages are its Bot tab. A conversation left pushed under another
        // tab is not on screen: what finishes there meanwhile is marked unread, and the watch told.
        .onChange(of: tab) { _, tab in
            guard usesTabs else { return }
            botOpen = tab == .bot
            app.currentSession = shownSession
        }
        .onChange(of: botOpen) { _, open in if usesTabs, open { tab = .bot } }
        // Back to the list on the 会话 tab: no conversation on screen any more.
        .onChange(of: sessionsPath) { _, path in
            guard usesTabs else { return }
            let top = path.last?.session
            if top != selection { selection = top }
        }
    }

    /// The layout with what the window follows: its launch, the page it is on, and the requests
    /// the model raises. Apart from `body`, as `layout` is: one chain of all of it is more than
    /// the compiler type-checks in the time it allows itself (Xcode 26 gives up on it).
    private var shell: some View {
        layout
        .inkTint()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .focusedSceneValue(\.windowCommands, windowCommands)
        .task(id: app.workspaces.map(\.id)) { launched() }
        .onChange(of: place) { _, place in
            if placeRestored, let place { UserDefaults.standard.set(place, forKey: Self.placeKey) }
        }
        // Which store this copy came from: only an App Store install is asked for a rating.
        .task { await AppDistribution.refresh() }
        // The sidebar's Mini Apps row; with the tab bar the page is a row of 探索.
        .onChange(of: app.miniAppsRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.miniAppsRequest = nil
            openMiniApps()
        }
        // The sidebar's 快捷指令 row (an iPad before iOS 18); elsewhere the page is under 探索.
        .onChange(of: app.shortcutsRequest) { _, token in
            guard token != nil, scenePhase != .background else { return }
            app.shortcutsRequest = nil
            sheet = .shortcuts
        }
        .task(id: canAnnounce) {
            guard canAnnounce else { return }
            if let actions = NodeEngine.shared.takeRecoveryReport() {
                recovered = actions
                return
            }
            if let release = WhatsNew.take() {
                newsShown = true
                whatsNew = release
                return
            }
            await UpdateChecker.shared.checkIfDue()
            guard !newsShown, let update = UpdateChecker.shared.takeAnnouncement() else { return }
            app.showToast(String(localized: "发现新版本 \(update.version)"), action: String(localized: "更新")) { openURL(update.url) }
        }
        // After a pause, and only into a quiet app: otherwise the next finished turn asks instead.
        .task(id: app.supportMoment) {
            guard app.supportMoment > 0 else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, canAnnounce, app.toast == nil, app.currentSession == selection,
                  !app.sessions.values.contains(where: \.running), let ask = SupportPrompt.take() else { return }
            switch ask {
            // The system decides whether its sheet shows, and never says.
            case .review: requestReview()
            case .support: supportDialog = true
            }
        }
        // Windows take turns: what is read is the one in front.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Folded or opened while away: that one counts.
                settle(sizeClass)
                app.currentSession = shownSession
                ReadAloud.shared.scope = onScreen
            }
            if phase == .background { widthOnLeaving = windowWidth }
        }
        // Reading aloud belongs to the conversation on screen: moving to another one stops it.
        .onChange(of: onScreen, initial: true) { _, session in ReadAloud.shared.scope = session }
        .onChange(of: shownBotChat, initial: true) { _, chat in app.botTeam.visibleChat = chat }
        .onChange(of: selection) { _, id in
            app.currentSession = shownSession
            if usesTabs {
                showInTabs(id)
                return
            }
            if launchedUnderBot { launchedUnderBot = false } else { botOpen = false }
            if let id {
                remember(workspaceOf: id)
            } else {
                newConversation(in: workspace)
            }
        }
        // An archived current session leaves the main view (here, the drawer, a follow push).
        .onChange(of: app.archived) { _, archived in
            if let selection, archived.contains(selection) { self.selection = nil }
        }
        // `app.open(session:)`: toasts, the subagent catalog, schedules…
        .onChange(of: app.openRequest?.token) { _, token in
            guard token != nil, scenePhase != .background, let id = app.openRequest?.id else { return }
            app.openRequest = nil
            // Asked for over a sheet (a toast there): the sheet goes, or the session opens unseen behind it.
            sheet = nil
            botOpen = false
            selection = id
            if usesTabs { showInTabs(id) }
            setDrawer(false)
        }
        .onChange(of: app.newSessionRequest?.token) { _, token in
            guard token != nil, scenePhase != .background, let request = app.newSessionRequest else { return }
            app.newSessionRequest = nil
            sheet = nil
            storeOpen = false
            // The conversation shows in place of the Bot pages too. The engine may hand back the
            // blank conversation already selected, and then no change of selection closes them.
            botOpen = false
            launchedUnderBot = false
            setDrawer(false)
            Task {
                // As a link does: a request made as the app comes up (one typed in the Mini Apps bar)
                // waits for the workspaces and the launch's own blank conversation, not dropped.
                let deadline = ContinuousClock.now + .seconds(10)
                while app.workspaces.isEmpty || creating, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let target = request.workspaceId.flatMap { id in app.workspaces.first { $0.id == id } } ?? workspace
                if let target { workspaceId = target.id }
                newConversation(in: target, agentPreset: request.agentPreset, draft: request.draft, prompt: request.prompt)
            }
        }
        .onChange(of: app.credentialRequest?.token) { _, token in
            guard token != nil, scenePhase != .background, let step = app.credentialRequest?.step else { return }
            app.credentialRequest = nil
            Task { await openCredentials(step) }
        }
        #if DEBUG
        .task { openForChecks() }
        #endif
    }

    /// The workspaces are known, and with them which sessions there are: back to the page the
    /// app was last on, or a blank conversation.
    private func launched() {
        guard !app.workspaces.isEmpty else { return }
        if !placeRestored {
            placeRestored = true
            restorePlace()
            // On the tab bar someone with no conversation yet has nothing to see in the list: the
            // new conversation page is where they start. Back from it is the (empty) list.
            if usesTabs, selection == nil, tab == .sessions, !hasConversations { newConversation(in: workspace) }
        }
        if selection == nil, !usesTabs { newConversation(in: workspace) }
    }

    /// Any conversation of the user's, archived ones and those on a computer included; the Bots' are not.
    private var hasConversations: Bool {
        if app.remote.signedIn { return true }
        return app.workspaces.contains { !app.sessions(in: $0, includeArchived: true).isEmpty }
            || !app.sessions(in: nil, includeArchived: true).isEmpty
    }

    /// The conversation the user is looking at (`AppModel.currentSession`): on the tab bar, only
    /// while the 会话 tab is in front.
    private var shownSession: String? {
        usesTabs && tab != .sessions ? nil : selection
    }

    /// The tab bar is the layout (`layout`): in every width from iOS 18, and on an iPhone before
    /// it. An iPad before iOS 18 keeps the sidebar: the tab bar of that time stays at the bottom
    /// however wide the window is.
    private var usesTabs: Bool {
        if #available(iOS 18.0, *) { true } else { UIDevice.current.userInterfaceIdiom == .phone }
    }

    /// Where there is room for the session list beside the conversation, on the tab bar's 会话 tab,
    /// and for the Bot list beside the chat on its Bot tab.
    private var sessionsSideBySide: Bool { usesTabs && layoutWidth == .regular }

    /// The window's width changed on screen (an iPad window resized, iPhone Duo folded or opened).
    private func settle(_ size: UserInterfaceSizeClass?) {
        guard size != layoutWidth else { return }
        settledWidth = size
        // On an iPad before iOS 18, a window narrowed past the sidebar has no place beside it for the store.
        // The tab bar keeps its tabs in every width.
        if !usesTabs, size != .regular, storeOpen {
            storeOpen = false
            sheet = .store
        }
        // Wide again: the system put the 会话 tab's list away on the way down, before the
        // conversation was pushed over it. It comes back.
        if usesTabs, size == .regular {
            sessionsColumns = .all
            botColumns = .all
        }
    }

    /// `selection` on the tab bar: a session is pushed on the 会话 tab, in front; none, it is popped.
    private func showInTabs(_ id: String?) {
        guard let id else {
            sessionsPath.removeAll()
            return
        }
        remember(workspaceOf: id)
        launchedUnderBot = false
        tab = .sessions
        if sessionsPath.last != .session(id) { sessionsPath = [.session(id)] }
    }

    #if DEBUG
    /// Screenshots and UI checks: `simctl launch … -dshOpen drawer|workbench|approval|question|timeline|settings|imagegen|plugins|store|schedules|signin|support|share|watch|connectors|whatsnew|capabilities|phonecontrol|shortcuts|remote|start|fishpocket|credits|topup|miniapps|miniapp`.
    /// `miniapp` opens the tool `-dshApp <id>` names.
    /// The conversation takes `workbench|filesearch|approval|question|timeline` itself; `filesearch` is the workbench's
    /// file search, with `-dshQuery <text>` to start it on a search.
    private func openForChecks() {
        switch UserDefaults.standard.string(forKey: "dshOpen") {
        case "drawer": drawerOpen = true
        case "settings": sheet = .settings
        case "plugins": sheet = .plugins
        case "store": openPlugins()
        case "schedules": sheet = .schedules
        case "signin": sheet = .signIn
        case "support": supportDialog = true
        case "share": sheet = .share
        case "watch": sheet = .watch
        case "connectors": sheet = .connectors
        case "imagegen": sheet = .imageGen
        case "whatsnew": whatsNew = WhatsNew.current
        case "capabilities": sheet = .capabilities
        case "phonecontrol": sheet = .phoneControl
        case "shortcuts": if usesTabs { tab = .explore; explorePath = [.shortcuts] } else { sheet = .shortcuts }
        case "remote": sheet = .remote
        case "start": Task { await openCredentials(.start) }
        // `credits` goes on to 积分明细 (FishPocketPage pushes it when it sees the argument).
        case "fishpocket", "credits": sheet = .fishPocket
        case "topup": app.fishPocket.quotaPrompt = true
        case "miniapps": openMiniApps()
        case "miniapp": MiniAppPresenter.open(UserDefaults.standard.string(forKey: "dshApp") ?? "")
        // The call screen over whatever is open, without a conversation behind it (`call` is a real one).
        case "callscreen":
            Task {
                try? await Task.sleep(for: .seconds(2))
                CallCenter.shared.start(sessionId: "call-screen-check", botId: nil, title: String(localized: "语音通话"), app: app)
            }
        default: break
        }
    }
    #endif

    /// What a sheet of the shell shows.
    @ViewBuilder
    private func page(of sheet: Sheet) -> some View {
        switch sheet {
        case .settings: SettingsView()
        // Pages 设置 also holds look the same opened from here: the system's lists.
        case .plugins: SheetStack { PluginsView() }.environment(\.systemLists, true)
        case .store: SheetStack { PluginStoreView() }
        case .schedules: SheetStack { SchedulesView(openSession: open(session:)) }.environment(\.systemLists, true)
        case .signIn: SignInSheet()
        case .cordis: CordisPanelView(currentSession: selection)
        case .share: SheetStack { ShareAppPage() }
        case .watch: SheetStack { WatchSetupPage() }
        case .capabilities: SheetStack { NativeCapabilitiesView() }.environment(\.systemLists, true)
        // The services ordinary conversations and Bots both reach; the Bot team's settings hold the same page.
        case .connectors: SheetStack { BotConnectorsPage() }.settingsStyle()
        case .phoneControl: SheetStack { PhoneControlView() }.environment(\.systemLists, true)
        case .remote: SheetStack { RemoteControlPage() }.environment(\.systemLists, true)
        case .fishPocket: SheetStack { FishPocketPage() }
        // 设置 → DeepSeek 账号, opened from Shortcuts' 查看余额.
        case .deepSeekAccount: SheetStack { AccountPage() }.settingsStyle()
        case .miniApps: SheetStack { MiniAppsPage() }
        // 设置 → 生图, opened straight from a failed image in a conversation.
        case .imageGen: SheetStack { ImageGenSettingsPage() }.settingsStyle()
        case .shortcuts: SheetStack { ShortcutsGuidePage() }
        }
    }

    var body: some View {
        shell
        .sheet(item: $sheet) { page(of: $0).sheetNotices() }
        .sheet(item: $onboarding, onDismiss: onboardingDismissed) { step in
            switch step {
            case .signIn(let ref, let autoStart):
                SignInSheet(
                    autoStart: autoStart,
                    addAPIKey: { keyEditorRef = ref },
                    useFishPocket: fishPocketOption
                )
            case .key(let ref):
                OnboardingKeySheet(ref: ref) { onboarding = nil }
            }
        }
        .sheet(item: $whatsNew) { WhatsNewSheet(release: $0) }
        .modifier(ShellDialogs())
        .overlay { ShellNotices() }
        .overlay {
            if supportDialog {
                SupportDialog(
                    rate: { settleSupport { openURL(AppLinks.appStoreReview) } },
                    share: { settleSupport { sheet = .share } },
                    // The card stays up: they may come back to rate.
                    repository: { Haptics.tap(); openURL(AppLinks.repository) },
                    later: { supportDialog = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(.snappy, value: supportDialog)
        // The Fish Pocket packs, opened from a conversation's out-of-balance card (QuotaNotice).
        .sheet(isPresented: Binding(get: { app.fishPocket.quotaPrompt }, set: { app.fishPocket.quotaPrompt = $0 })) {
            FishPocketTopUpSheet().sheetNotices()
        }
        .alert("引擎起来了", isPresented: Binding(get: { recovered != nil }, set: { if !$0 { recovered = nil } })) {
            if recovered?.contains(where: { $0.action == "safe-mode" && !($0.disabled ?? []).isEmpty }) == true {
                Button("去插件页") { sheet = .plugins }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text((recovered ?? []).map(EngineRepair.report).filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        .onChange(of: app.lastError) { _, error in if error != nil { Haptics.error() } }
        .alert("出错了", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(app.lastError ?? "")
        }
        .environment(\.openSession, OpenSessionAction(openSessionBox) { open(session: $0) })
        // This window's own: its pages' docks report here and its notices read here.
        .environment(docks)
    }

    // MARK: Credentials

    /// Without a reference (the official route is off) the key lives in settings, and signing in is all that is left.
    private func openCredentials(_ step: AppModel.CredentialStep) async {
        sheet = nil
        if case .settings = step { sheet = .settings; return }
        if case .fishPocket = step { sheet = .fishPocket; return }
        if case .imageGen = step { sheet = .imageGen; return }
        guard let ref = await app.officialKeyRef() else {
            if case .officialKey = step { sheet = .settings } else { sheet = .signIn }
            return
        }
        switch step {
        case .start, .signIn:
            if case .signIn = step { onboarding = .signIn(ref: ref, autoStart: true) } else { onboarding = .signIn(ref: ref) }
        case .officialKey:
            onboarding = .key(ref: ref)
        case .settings, .fishPocket, .imageGen:
            break
        }
    }

    /// The sign-in sheet's Fish Pocket way in, when this build has the service.
    private var fishPocketOption: (() -> Void)? {
        guard app.fishPocket.available else { return nil }
        return { fishPocketAfterOnboarding = true }
    }

    /// 「添加 API Key」 in the sign-in sheet hands over to the key editor once that sheet is gone.
    private func onboardingDismissed() {
        if fishPocketAfterOnboarding {
            fishPocketAfterOnboarding = false
            sheet = .fishPocket
            return
        }
        guard let ref = keyEditorRef else { return }
        keyEditorRef = nil
        onboarding = .key(ref: ref)
    }

    // MARK: Layouts

    private var split: some View {
        NavigationSplitView(columnVisibility: sidebarOnScreen) {
            // A width that follows the fold hangs the split view, on the one layout pass where
            // the window has turned and the width has not. These fit every pose.
            drawer.navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
                .toolbar(.hidden, for: .navigationBar)
                .modifier(SidebarToggle(system: systemSidebarButton))
        } detail: {
            Group {
                if storeOpen {
                    NavigationStack { PluginStoreView(openSidebar: hideSidebar) }
                } else if botOpen {
                    DetailPath(path: $botPath) { botStackInSplit(path: $0) }
                } else {
                    NavigationStack { conversation(openDrawer: hideSidebar) }
                }
            }
            .modifier(PastTheFold())
            // Every conversation in the detail, a Bot's chat too, can ask for the sidebar's room.
            .environment(\.splitSidebar, SplitSidebar(makeRoom: makeRoomForWorkbench))
        }
        // Side by side wherever both fit. Where they do not, the system keeps the sidebar
        // away and its button slides it over the conversation.
        .navigationSplitViewStyle(.balanced)
        // This layout stays while the window is drawn narrow out of sight (`settledWidth`), and the
        // split view has to stay as it is too. Following the window, it folds into one column and
        // opens again, and in between a page pushed in its detail is laid out without the
        // environment from outside its stack: with a Bot's chat or a plugin's page open, the app
        // crashed in the background (no `AppModel`), and a page that got through that came back
        // without its toolbar. It keeps its width as well: squeezed beside the sidebar, a pushed
        // page came back with the title gone from its back button.
        .environment(\.horizontalSizeClass, .regular)
        .frame(minWidth: scenePhase == .background ? widthOnLeaving : nil)
        // With one kind of path in the detail (`botStackInSplit`), the split view keeps the pages
        // links pushed as one stack takes another's place: a plugin's page stayed over the Bot
        // list, a file from the workbench over the conversation a Bot's chat was left for. They go
        // with the stack they were pushed on.
        .onChange(of: storeOpen ? 0 : botOpen ? 1 : 2) { SplitDetail.popToRoot() }
    }

    /// The sidebar, as the split view is given it. Kept wide while the window is drawn narrow out
    /// of sight, the split view brings back a sidebar that was away (for the workbench) and says
    /// so. That is not followed: back on screen, the sidebar is away as it was left.
    private var sidebarOnScreen: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebar }, set: { if scenePhase != .background { sidebar = $0 } })
    }

    /// Whether the system's sidebar button stays. From iOS 27.1 it has to: removed, a split
    /// view too narrow for both columns (iPhone Duo open and held upright) has no way to put
    /// the sidebar away, and its layout never settles: the app hangs there and on the next
    /// rotation. Before that there is no such device, and the system's button cannot be
    /// counted on: with the sidebar away, iPadOS 26 shows none in the conversation's bar.
    private var systemSidebarButton: Bool {
        if #available(iOS 27.1, *) { true } else { false }
    }

    /// Our button puts a shown sidebar away. Where the system's button stays, a hidden one
    /// comes back with it, in the same place in the bar: one of the two at a time. Elsewhere
    /// ours does both.
    private var hideSidebar: (() -> Void)? {
        systemSidebarButton && sidebar == .detailOnly ? nil : toggleSidebar
    }

    private var windowCommands: WindowCommands {
        WindowCommands(
            windowCommandsBox,
            newConversation: {
                sheet = nil
                storeOpen = false
                newConversation(in: workspace)
                setDrawer(false)
            },
            newWindow: supportsMultipleWindows ? { openWindow(id: DshIOSApp.window) } : nil,
            search: {
                sheet = nil
                if usesTabs {
                    // Search is the 会话 tab's own field: over the list where the list is under the
                    // conversation, beside it where it is wide (the conversation stays).
                    tab = .sessions
                    if sessionsSideBySide {
                        withAnimation { sessionsColumns = .all }
                    } else {
                        sessionsPath.removeAll()
                    }
                    searchRequest += 1
                    return
                }
                if layoutWidth == .regular { withAnimation { sidebar = .all } } else { setDrawer(true) }
                searchRequest += 1
            },
            toggleSidebar: toggleSidebar,
            openSettings: { sheet = .settings }
        )
    }

    private func toggleSidebar() {
        // On the tab bar the 会话 tab's list, or the Bot tab's, where it is beside the chat.
        if usesTabs {
            if sessionsSideBySide, tab == .sessions { toggleSessionsList() }
            if sessionsSideBySide, tab == .bot { toggleBotList() }
            return
        }
        if layoutWidth == .regular {
            withAnimation { sidebar = sidebar == .detailOnly ? .all : .detailOnly }
        } else {
            setDrawer(!drawerOpen)
        }
    }

    /// The workbench takes about 420 pt: under this much, the conversation would be left too little.
    private func makeRoomForWorkbench() {
        if windowWidth < 1100 { withAnimation { sidebar = .detailOnly } }
    }

    private var drawerLayout: some View {
        GeometryReader { geometry in
            let width = min(326, geometry.size.width - 64)
            // Closed, the drawer has to clear the leading safe area too: in landscape that strip
            // (the camera's side) is on screen, and the drawer's edge would show in it.
            let travel = width + geometry.safeAreaInsets.leading
            let progress = min(1, max(0, (drawerOpen ? 1 : 0) + drag / width))
            ZStack(alignment: .leading) {
                Group {
                    if botOpen {
                        botStack(openDrawer: { setDrawer(true) })
                    } else {
                        NavigationStack { conversation(openDrawer: { setDrawer(true) }) }
                    }
                }
                .accessibilityHidden(drawerOpen)
                Palette.scrim
                    .opacity(progress)
                    .ignoresSafeArea()
                    .allowsHitTesting(progress > 0)
                    .onTapGesture { setDrawer(false) }
                    .accessibilityLabel("关闭侧边栏")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHidden(!drawerOpen)
                drawer
                    .frame(width: width)
                    .offset(x: (progress - 1) * travel)
                    .accessibilityHidden(!drawerOpen)
            }
            .background {
                DrawerEdgePan(enabled: !drawerOpen) { translation in
                    if drag == 0 { dismissKeyboard() }
                    drag = max(0, translation)
                } ended: { predicted in
                    settleDrawer(predicted: predicted, width: width)
                }
            }
            // A leftward swipe closes, from the dimmed side or anywhere in the drawer but a session
            // row (there it reveals the row's actions). It follows the finger and settles by distance
            // or speed. A recogniser that only begins sideways, not a drag gesture on this view: that
            // one ran through every scroll of the session list, and redrew this view as each began and ended.
            .background {
                DrawerClosePan(enabled: drawerOpen) { start in
                    start.x > width || !rowFrames.hasRow(atY: start.y)
                } changed: { translation in
                    drag = min(0, translation)
                } ended: { predicted in
                    if predicted == 0, drag != 0 {
                        withAnimation(.snappy(duration: 0.25)) { drag = 0 }
                    } else {
                        settleDrawer(predicted: predicted, width: width)
                    }
                }
            }
        }
    }

    private func settleDrawer(predicted: CGFloat, width: CGFloat) {
        guard drag != 0 else { return }
        let open = drawerOpen ? predicted > -width / 2 : predicted > width / 2
        if open != drawerOpen { Haptics.select() }
        withAnimation(.snappy(duration: 0.25)) {
            drawerOpen = open
            drag = 0
        }
    }

    /// Show `id` from wherever it was asked for: over a sheet it closes first.
    private func open(session id: String) {
        sheet = nil
        botOpen = false
        selection = id
        if usesTabs { showInTabs(id) }
        setDrawer(false)
    }

    /// 插件, from the sidebar or the new conversation page.
    private func openPlugins() {
        setDrawer(false)
        if usesTabs {
            sheet = nil
            tab = .explore
            if explorePath.last != .plugins { explorePath = [.plugins] }
        } else if layoutWidth == .regular { storeOpen = true } else { sheet = .store }
    }

    /// Mini Apps: a page of 探索 with the tab bar, a sheet over the iPad's sidebar before iOS 18.
    private func openMiniApps() {
        if usesTabs {
            sheet = nil
            tab = .explore
            if explorePath.last != .miniApps { explorePath = [.miniApps] }
        } else { sheet = .miniApps }
    }

    private func setDrawer(_ open: Bool) {
        if open { dismissKeyboard() }
        withAnimation(.snappy(duration: 0.25)) { drawerOpen = open }
    }

    private var drawer: some View { drawer(.sidebar) }

    private func drawer(_ style: DrawerView.Style) -> some View {
        DrawerView(
            selection: selection,
            workspace: workspace,
            rowFrames: rowFrames,
            pluginsSelected: storeOpen,
            select: { id in storeOpen = false; botOpen = false; selection = id; if usesTabs { showInTabs(id) }; setDrawer(false) },
            newConversation: { workspace in storeOpen = false; botOpen = false; workspaceId = workspace.id; newConversation(in: workspace); setDrawer(false) },
            openSettings: { sheet = .settings },
            openSchedules: { sheet = .schedules },
            openCordis: { sheet = .cordis },
            openSignIn: { sheet = .signIn },
            searchRequest: searchRequest,
            openInWindow: supportsMultipleWindows ? { openWindow(id: DshIOSApp.window, value: SessionWindow(session: $0)) } : nil,
            style: style
        )
    }

    // MARK: Tab bar

    /// The layout from iOS 18. Where the bar is at the bottom, a conversation, a Bot's chat or a
    /// group, pushed, keeps it: the input sits above it.
    @available(iOS 18.0, *)
    private var tabLayout: some View {
        TabView(selection: $tab) {
            Tab(value: HomeTab.sessions) {
                if sessionsSideBySide { sessionsSplit } else { sessionsStack }
            } label: {
                tabLabel(Text(DrawerView.sessionsTitle), "fp.message", custom: true)
            }
            .badge(badges.waiting)
            Tab(value: HomeTab.bot) {
                if sessionsSideBySide { botSplit } else { botStack(openDrawer: nil) }
            } label: {
                tabLabel(Text(verbatim: "Bot"), "fp.bot", custom: true)
            }
            .badge(badges.botPending)
            Tab(value: HomeTab.explore) {
                ExploreTabView(path: $explorePath)
            } label: {
                tabLabel(Text("探索"), "square.grid.2x2")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .background(TabBarAppearanceFollower())
        // iPhone Duo open keeps a column at its trailing edge for the bar buttons and the tab bar. The
        // system settles what goes there when the tab view is made: made folded, then opened, the
        // buttons of the conversation beside the list never show. Made again at each fold, it holds
        // everything that counts outside it (the tab, each tab's path, the conversation).
        .id(ThisDevice.isDuo ? layoutWidth : nil)
    }

    /// The iPhone's layout before iOS 18: the same tabs, on the tab bar of that time. Its `Tab`
    /// and `.sidebarAdaptable` came with iOS 18; this one is at the bottom in every width, and
    /// a phone held sideways (the big ones are wide then) keeps the 会话 and Bot tabs' lists beside
    /// the chat, as it is from iOS 18.
    private var phoneTabLayout: some View {
        TabView(selection: $tab) {
            Group { if sessionsSideBySide { sessionsSplit } else { sessionsStack } }
                .tabItem { tabLabel(Text(DrawerView.sessionsTitle), "fp.message", custom: true) }
                .tag(HomeTab.sessions)
                .badge(badges.waiting)
            Group { if sessionsSideBySide { botSplit } else { botStack(openDrawer: nil) } }
                .tabItem { tabLabel(Text(verbatim: "Bot"), "fp.bot", custom: true) }
                .tag(HomeTab.bot)
                .badge(badges.botPending)
            ExploreTabView(path: $explorePath)
                .tabItem { tabLabel(Text("探索"), "square.grid.2x2") }
                .tag(HomeTab.explore)
        }
    }

    /// The 会话 tab where it is narrow: the list, with the conversation pushed over it.
    private var sessionsStack: some View {
        NavigationStack(path: $sessionsPath) {
            drawer(.sessions)
                .navigationDestination(for: DrawerView.Route.self) { route in
                    switch route {
                    case .session(let id): pushedConversation(id)
                    }
                }
        }
    }

    /// The 会话 tab where it is wide: the list beside the conversation, which is always there, as the
    /// split view's: with none selected (at launch, after archiving) a blank one opens.
    private var sessionsSplit: some View {
        NavigationSplitView(columnVisibility: $sessionsColumns) {
            // Nothing in this column pushes: a link here went to the conversation's column, with no
            // way back (#284), and a stack of the column's own put the system's sidebar button in
            // the list's bar for good on iPadOS 18. 「已归档」 is in 设置 for that.
            drawer(.sessions)
            // Widths as the split view's (`split`): a width that follows the fold hangs it.
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
            .modifier(SidebarToggle(system: systemSidebarButton))
            .modifier(BelowFloatingTabBar())
        } detail: {
            NavigationStack {
                if let selection { pushedConversation(selection) } else { conversation(openDrawer: nil) }
            }
            .modifier(PastTheFold())
            .modifier(BelowFloatingTabBar())
            // The list's button where the system's cannot be counted on (`systemSidebarButton`), and
            // room for the workbench.
            .environment(\.splitSidebar, SplitSidebar(makeRoom: makeRoomInSessions, toggle: sessionsListToggle))
        }
        .navigationSplitViewStyle(.balanced)
        // This is the layout while the width on screen is regular (`settledWidth`), and the split
        // view stays as it is while the window is drawn narrow out of sight, as the one before
        // iOS 18 does (`split`). Following the window, it folds into one column and opens again:
        // on iPadOS 18 the list then came back with an empty bar, its buttons and search field
        // gone until the next launch, and on iPhone Duo it came back put away.
        .environment(\.horizontalSizeClass, .regular)
        // Only while this tab is in front: a conversation archived from another one does not pull it here.
        .task(id: selection == nil && !app.workspaces.isEmpty && tab == .sessions) {
            if selection == nil, !app.workspaces.isEmpty, tab == .sessions { newConversation(in: workspace) }
        }
    }

    /// The 会话 tab's list button in the conversation's bar, where the system's is removed
    /// (`systemSidebarButton`). From iOS 27.1 the system's is there, beside the list's own buttons
    /// and in the conversation's bar once the list is away: a second one would say the same.
    private var sessionsListToggle: (() -> Void)? {
        systemSidebarButton ? nil : toggleSessionsList
    }

    private func toggleSessionsList() {
        if TabSidebar.foldOffList() {
            withAnimation { sessionsColumns = .all }
            return
        }
        withAnimation { sessionsColumns = sessionsColumns == .detailOnly ? .all : .detailOnly }
    }

    /// The workbench takes about 420 pt: under this much, the list makes way for it, as the sidebar does.
    private func makeRoomInSessions() {
        if windowWidth < 1100 { withAnimation { sessionsColumns = .detailOnly } }
    }

    /// A tab's icon, outlined whether or not it is the one in front: left alone the system fills
    /// every icon that has a filled form, so it is told not to. On a phone the bar shows the icon
    /// alone, the name only to VoiceOver; an iPad keeps the name, which its tab bar at the top and
    /// its sidebar show as the tab itself. `custom` is one of our own symbols in the asset catalog
    /// (Symbols, drawn by `scripts/draw-tab-symbols.swift`), which follows weight and size like a
    /// system one.
    @ViewBuilder
    private func tabLabel(_ title: Text, _ symbol: String, custom: Bool = false) -> some View {
        let icon = (custom ? Image(symbol) : Image(systemName: symbol))
        if UIDevice.current.userInterfaceIdiom == .phone {
            icon
                .environment(\.symbolVariants, .none)
                .accessibilityLabel(title)
        } else {
            Label { title } icon: { icon }
                .environment(\.symbolVariants, .none)
        }
    }

    /// A conversation on the 会话 tab's stack. Back is the system's; there is no drawer to open.
    @ViewBuilder
    private func pushedConversation(_ id: String) -> some View {
        if let remote = RemoteStore.sessionId(of: id) {
            RemoteConversationView(sessionId: remote, selection: $selection, openDrawer: nil)
                .id(id)
        } else {
            ConversationView(sessionId: id, selection: $selection, openDrawer: nil, switchWorkspace: { workspace in
                workspaceId = workspace.id
                newConversation(in: workspace)
            })
            .id(id)
        }
    }

    /// The session on screen: a Bot's chat or a group when the Bot pages are open, else the conversation.
    private var onScreen: String? {
        guard botOpen else { return selection }
        switch botPath.last {
        case .bot(let id): return app.botTeam.bot(id)?.sessionId ?? "bot:\(id)"
        case .room(let id): return app.botTeam.room(id)?.sessionId ?? "room:\(id)"
        case nil: return "bots"
        }
    }

    /// The Bot's chat or the group on screen (`BotModel.visibleChat`). Kept from here, as
    /// `currentSession` is, and not by the pages as they come and go: opening an iPhone Duo
    /// rebuilds them, and what they kept was lost on the way.
    private var shownBotChat: String? {
        guard botOpen else { return nil }
        switch botPath.last {
        case .bot(let id)?, .room(let id)?: return id
        case nil: return nil
        }
    }

    /// The Bot list, with a Bot's chat or a group pushed on it.
    private func botStack(openDrawer: (() -> Void)?) -> some View {
        NavigationStack(path: $botPath) { botList(openDrawer: openDrawer, path: $botPath) }
    }

    /// The same in the split view's detail (an iPad before iOS 18). `path` is `botPath` as the
    /// detail hands it over (`DetailPath`), and the stack is given it as a `NavigationPath`, the
    /// kind of path the two stacks it shares the detail with have. The split view takes the three
    /// for one stack and compares their paths as one follows another: with this one's an array of
    /// `BotRoute` it crashed there (`comparisonTypeMismatch`) whenever the Bot list was updated
    /// once more in the update it left in, as it is on the way to another conversation
    /// (`AppModel.currentSession` is set, and the list shows what is unread).
    private func botStackInSplit(path: Binding<[BotRoute]>) -> some View {
        NavigationStack(path: BotRoute.erased(path)) { botList(openDrawer: hideSidebar, path: path) }
    }

    private func botList(openDrawer: (() -> Void)?, path: Binding<[BotRoute]>) -> some View {
        BotHomeView(openDrawer: openDrawer, open: { path.wrappedValue = [$0] })
            .navigationDestination(for: BotRoute.self) { route in
                botPage(route)
                    // Set here as well: what the split view sets does not reach a pushed page. A pushed
                    // chat has a back button where the conversation has its sidebar button, so the
                    // sidebar's goes beside it. On the tab bar there is no sidebar: no button for one.
                    .environment(\.splitSidebar, SplitSidebar(makeRoom: makeRoomForWorkbench, toggle: !usesTabs && layoutWidth == .regular ? hideSidebar : nil))
                    // iPhone Duo open: no inspector on a pushed chat (see `workbenchInSheet`).
                    .environment(\.workbenchInSheet, usesTabs && ThisDevice.isDuo)
            }
    }

    /// The Bot tab where it is wide, as the 会话 tab: the list beside the chat. The first route on
    /// `botPath` is the one picked in the list; what a link pushes from there goes over it.
    private var botSplit: some View {
        NavigationSplitView(columnVisibility: $botColumns) {
            BotHomeView(openDrawer: nil, selection: Binding(get: { botPath.first }, set: { route in botPath = route.map { [$0] } ?? [] }), open: { botPath = [$0] })
                // Widths as the split view's (`split`): a width that follows the fold hangs it.
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
                .modifier(SidebarToggle(system: systemSidebarButton))
                .modifier(BelowFloatingTabBar())
        } detail: {
            DetailPath(path: Binding(get: { Array(botPath.dropFirst()) }, set: { botPath = Array(botPath.prefix(1)) + $0 })) { path in
                NavigationStack(path: path) {
                    Group {
                        if let route = botPath.first {
                            botPage(route).id(route)
                        } else {
                            Text("选一个 Bot 或群聊")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Palette.background)
                        }
                    }
                    .navigationDestination(for: BotRoute.self) { route in
                        // Pushed over the picked chat: no inspector on iPhone Duo (see `workbenchInSheet`).
                        botPage(route).environment(\.workbenchInSheet, ThisDevice.isDuo)
                    }
                }
            }
            .modifier(PastTheFold())
            .modifier(BelowFloatingTabBar())
            // The list's button where the system's cannot be counted on (`systemSidebarButton`), and
            // room for the workbench.
            .environment(\.splitSidebar, SplitSidebar(makeRoom: makeRoomInBots, toggle: systemSidebarButton ? nil : toggleBotList))
        }
        .navigationSplitViewStyle(.balanced)
        // As the 会话 tab's (`sessionsSplit`): not folded while the window is narrow out of sight.
        .environment(\.horizontalSizeClass, .regular)
    }

    private func toggleBotList() {
        if TabSidebar.foldOffList() {
            withAnimation { botColumns = .all }
            return
        }
        withAnimation { botColumns = botColumns == .detailOnly ? .all : .detailOnly }
    }

    /// As the 会话 tab's (`makeRoomInSessions`).
    private func makeRoomInBots() {
        if windowWidth < 1100 { withAnimation { botColumns = .detailOnly } }
    }

    @ViewBuilder
    private func botPage(_ route: BotRoute) -> some View {
        switch route {
        case .bot(let id): BotChatView(botId: id)
        case .room(let id): BotRoomView(roomId: id)
        }
    }

    @ViewBuilder
    private func conversation(openDrawer: (() -> Void)?) -> some View {
        if let selection, let remote = RemoteStore.sessionId(of: selection) {
            RemoteConversationView(sessionId: remote, selection: $selection, openDrawer: openDrawer)
                .id(selection)
        } else if let selection {
            ConversationView(sessionId: selection, selection: $selection, openDrawer: openDrawer, switchWorkspace: { workspace in
                workspaceId = workspace.id
                newConversation(in: workspace)
            })
            .id(selection)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.background)
                .toolbar { if let openDrawer { ToolbarItem(placement: .topBarLeading) { DrawerButton(action: openDrawer) } } }
        }
    }

    /// `fishpocket://session/<id>` opens the session; `fishpocket://new` a new conversation with the keyboard up,
    /// once the workspaces are known and the launch's own blank conversation is in place.
    private func follow(_ link: DshLink) async {
        // Taken already (by another window, or found waiting as the app came to the front): nothing to do.
        var shared: ShareInbox.Taken?
        if case .share(let id) = link {
            shared = ShareInbox.take(id)
            if shared == nil { return }
        }
        sheet = nil
        storeOpen = false
        setDrawer(false)
        switch link {
        case .session(let id):
            // A computer's session from the lock screen or a widget, after signing out: nothing to open.
            if RemoteStore.sessionId(of: id) != nil, !app.remote.signedIn { return }
            // A Bot's or a group's Session (the Live Activity and the widgets list every running
            // one): its chat on the Bot page, not the plain conversation.
            if RemoteStore.sessionId(of: id) == nil, let route = await teamRoute(of: id) {
                app.botTeam.openRequest = BotOpenRequest(route: route)
                return
            }
            selection = id
            if usesTabs { showInTabs(id) }
        case .new(let workspaceId, let preset, let draft):
            let deadline = ContinuousClock.now + .seconds(10)
            while app.workspaces.isEmpty || creating, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let target = workspaceId.flatMap { id in app.workspaces.first { $0.id == id } } ?? workspace
            if let target { self.workspaceId = target.id }
            newConversation(in: target, agentPreset: preset, draft: draft, focus: true)
        case .share:
            if let shared { await receive(shared) }
        case .app(let id):
            MiniAppPresenter.open(id)
        case .web:
            webOpen = true
        case .bot(let id):
            // A cold launch: the team arrives a moment after the engine.
            let deadline = ContinuousClock.now + .seconds(10)
            while app.botTeam.bot(id) == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if app.botTeam.bot(id) != nil {
                app.botTeam.openRequest = BotOpenRequest(route: .bot(id))
            } else {
                app.botTeam.openRequest = BotOpenRequest(route: nil)
                app.showToast(String(localized: "找不到这个 Bot 了"), tone: .warning)
            }
        case .balance:
            sheet = await balancePage()
        case .call:
            CallCenter.shared.expand()
        }
    }

    /// The Bot chat or group a Session belongs to, nil for one the Bot team does not run.
    /// A cold launch: the team arrives a moment after the engine, so its answer is waited for.
    private func teamRoute(of id: String) async -> BotRoute? {
        let deadline = ContinuousClock.now + .seconds(5)
        while app.botTeam.status == .unknown, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return app.botTeam.route(ofSession: id)
    }

    /// Where 查看余额 goes: the Fish Pocket account when signed in to it, else the DeepSeek account
    /// when signed in to that; with neither, Fish Pocket's page (it signs in and sells credits)
    /// when this build has the service.
    private func balancePage() async -> Sheet {
        guard app.fishPocket.available else { return .deepSeekAccount }
        if app.fishPocket.signedIn { return .fishPocket }
        // A cold launch: the account's state arrives a moment after the engine.
        let deadline = ContinuousClock.now + .seconds(3)
        while app.account.view == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return app.account.signedIn ? .deepSeekAccount : .fishPocket
    }

    /// What another app shared (the share extension): into the composer of the Bot, the group or
    /// the new conversation picked there, keyboard up, nothing sent.
    private func receive(_ shared: ShareInbox.Taken) async {
        let files = shared.files.isEmpty ? nil : SharedFiles(urls: shared.files, folder: shared.folder)
        if files == nil { try? FileManager.default.removeItem(at: shared.folder) }
        if case .bot(let botId) = shared.target {
            // A cold launch: the team arrives a moment after the engine.
            let deadline = ContinuousClock.now + .seconds(10)
            while app.botTeam.bot(botId) == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let bot = app.botTeam.bot(botId), !bot.sessionId.isEmpty {
                deliver(text: shared.text, files: files, to: bot.sessionId)
                app.botTeam.openRequest = BotOpenRequest(route: .bot(botId))
                return
            }
            app.showToast(String(localized: "找不到这个 Bot 了，内容放进了新对话"), tone: .warning)
        }
        if case .room(let roomId) = shared.target {
            let deadline = ContinuousClock.now + .seconds(10)
            while app.botTeam.room(roomId) == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let room = app.botTeam.room(roomId), !room.sessionId.isEmpty {
                deliver(text: shared.text, files: files, to: room.sessionId)
                app.botTeam.openRequest = BotOpenRequest(route: .room(roomId))
                return
            }
            app.showToast(String(localized: "找不到这个群聊了，内容放进了新对话"), tone: .warning)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while app.workspaces.isEmpty || creating, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        launchedUnderBot = false
        botOpen = false
        newConversation(in: workspace, draft: shared.text, files: files, focus: true)
    }

    /// Text and files waiting for a session's composer, which takes them when it shows.
    private func deliver(text: String?, files: SharedFiles?, to id: String) {
        if let text { app.pendingDrafts[id] = text }
        if let files { app.pendingFiles[id] = files }
        app.pendingFocus.insert(id)
    }

    /// Open a blank conversation in `workspace` (the engine reuses a blank one there).
    private func newConversation(in workspace: Workspace?, agentPreset: String? = nil, draft: String? = nil, files: SharedFiles? = nil, prompt: String? = nil, focus: Bool = false) {
        guard let workspace, !creating else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                let id = try await app.createSession(in: workspace, agentPreset: agentPreset)
                if let draft { app.pendingDrafts[id] = draft }
                if let files { app.pendingFiles[id] = files }
                if let prompt { app.pendingPrompts[id] = prompt }
                if focus { app.pendingFocus.insert(id) }
                // iOS 17 drops a push made in the update that brings the new blank conversation into
                // the session list (`createSession` refreshes it): the path holds the conversation and
                // the list stays on screen, so 新对话 seemed to do nothing. A turn later it is shown.
                if #unavailable(iOS 18) { try? await Task.sleep(for: .milliseconds(30)) }
                selection = id
                // The engine may hand back the blank conversation already selected: shown all the same.
                if usesTabs { showInTabs(id) }
            }
            catch {
                if let files { try? FileManager.default.removeItem(at: files.folder) }
                app.showToast(String(localized: "新建会话失败：\(error.localizedDescription)"), tone: .warning, duration: 6)
            }
        }
    }
}

/// The tab bar opened into a sidebar (`sidebarAdaptable`, on an iPad).
@MainActor
private enum TabSidebar {
    /// Before iOS 26 the sidebar lies over the window's leading edge and the tab's page is not
    /// made narrower for it: the 会话 or Bot list, the split view's first column, is under it, and
    /// showing or hiding that column changes nothing in sight. Asked for the list there, the
    /// sidebar folds back into the tab bar, which uncovers it. True when it did.
    static func foldOffList() -> Bool {
        guard #available(iOS 18.0, *) else { return false }
        if #available(iOS 26.0, *) { return false }
        guard let tabs = controller, !tabs.sidebar.isHidden else { return false }
        tabs.sidebar.isHidden = true
        return true
    }

    /// The tab bar controller of the window in front: the one whose button was just tapped.
    private static var controller: UITabBarController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var pending = [(windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController].compactMap { $0 }
        while let next = pending.popLast() {
            if let tabs = next as? UITabBarController { return tabs }
            pending.append(contentsOf: next.children)
        }
        return nil
    }
}

/// iOS 18 on an iPhone: the tab bar takes a new appearance (深色 → 浅色) but its buttons and its
/// background keep the old one. The unselected icons were drawn in dark mode's grey over a light
/// page, almost invisible, the badges in dark mode's red, and the bar's background, where a list
/// ran under it (探索), dark; switching tabs did not bring it back, only a new launch. The bar
/// itself has the new appearance, nothing overrides its subviews' (seen in the debugger): UIKit
/// does not pass the change on to them. Changing the bar's own once more does, so after each
/// change, where they still differ, it is set to the other appearance and back, at once, which
/// draws nothing in between. iOS 26 and the iPad are not affected; iOS 17 has no `Tab`.
private struct TabBarAppearanceFollower: UIViewRepresentable {
    func makeUIView(context: Context) -> Follower { Follower() }
    func updateUIView(_ view: Follower, context: Context) {}

    final class Follower: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            guard #unavailable(iOS 26.0), UIDevice.current.userInterfaceIdiom == .phone else { return }
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Follower, _: UITraitCollection) in
                // After UIKit and SwiftUI are done with the change, and once more a moment later
                // for a bar SwiftUI updates after that.
                DispatchQueue.main.async { view.refresh() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { view.refresh() }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        /// The tab bar of this window: the tab view's controller is beside this view, not above it.
        private var bar: UITabBar? {
            var pending = [window?.rootViewController].compactMap { $0 }
            while let next = pending.popLast() {
                if let tabs = next as? UITabBarController { return tabs.tabBar }
                pending.append(contentsOf: next.children)
            }
            return nil
        }

        private func refresh() {
            guard let bar, bar.overrideUserInterfaceStyle == .unspecified else { return }
            let style = bar.traitCollection.userInterfaceStyle
            guard bar.subviews.contains(where: { $0.traitCollection.userInterfaceStyle != style }) else { return }
            bar.overrideUserInterfaceStyle = style == .dark ? .light : .dark
            bar.layoutIfNeeded()
            bar.overrideUserInterfaceStyle = .unspecified
            bar.layoutIfNeeded()
        }
    }
}

/// The detail column of the split view (an iPad before iOS 18) in the window in front.
@MainActor
private enum SplitDetail {
    /// Back to the column's first page, unanimated. SwiftUI follows it as it follows the back button.
    static func popToRoot() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var pending = [(windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController].compactMap { $0 }
        while let next = pending.popLast() {
            guard let split = next as? UISplitViewController else {
                pending.append(contentsOf: next.children)
                continue
            }
            let detail = split.viewController(for: .secondary)
            guard let stack = (detail as? UINavigationController) ?? detail?.navigationController, stack.viewControllers.count > 1 else { return }
            stack.popToRootViewController(animated: false)
            // Carried out now: left for the next layout, the pages are still there when SwiftUI
            // next sets the column's, and they stay.
            stack.view.layoutIfNeeded()
            return
        }
    }
}

/// On the sidebar column: the system's sidebar button, kept or removed (`systemSidebarButton`).
private struct SidebarToggle: ViewModifier {
    let system: Bool

    func body(content: Content) -> some View {
        if system { content } else { content.toolbar(removing: .sidebarToggle) }
    }
}

/// iPadOS 18 floats the tab bar at the top of the window, over the bars below it. A bar the
/// width of the window keeps its items clear of it (it grows, and its title goes to a second row);
/// the bars of a split view's columns do not: the conversation's title, centred in its column, sat
/// under the tab bar (a new conversation's model picker could not be read or tapped), and so did
/// the buttons near it. While the tab bar is there, the 会话 and Bot tabs' split views start under it.
/// From iOS 26 the system does this itself, but loses it when the sidebar folds back into the tab
/// bar; on iOS 27 it also has two ways of doing it and has to be kept to one (`SplitBelowTabBar`).
/// A phone's tab bar is at the bottom.
private struct BelowFloatingTabBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad {
            content.background(SplitBelowTabBar())
        } else {
            content
        }
    }
}

/// The split view's bars are UIKit's, laid out from its safe area: what SwiftUI insets or pads
/// inside a column does not move them. So before iOS 26 the split view controller's own safe area
/// is pushed down by one bar, and back up once the tab bar is away (turned into the sidebar, or
/// hidden). It is in both columns: the sidebar can take the tab bar's place without the
/// conversation's column changing size, and then the list is what goes or comes back.
///
/// iOS 27 keeps the bars clear by itself, but not the same way each time (seen on iPadOS 27.2;
/// 26.4 does not do this). A tab shown for the first time has the tab bar's height in its page's
/// safe area, and the split view starts below the bar. Shown again, the page's safe area is the
/// window's, the split view starts under the tab bar, and its columns' bars are moved down
/// instead. The first turns into the second piecemeal: the split view moves its bars down as soon
/// as its own layout changes (the list hidden, a sheet with the keyboard up) while the page still
/// keeps it below the tab bar, and both title rows stand a row too low until the tab is left and
/// come back to. So a page found the first way is made to work its safe area out again, which
/// takes it to the second at once, where it stays.
///
/// The second way is lost when the sidebar folds back into the tab bar (upright, where it lies
/// over the page; seen on iPadOS 27.2, and 26.4 ends up the same): the columns' bars are not
/// moved down again and stay under the tab bar until the list is hidden and shown. A tab picked
/// in that sidebar and shown for the first time comes up the same. A column found there has its
/// page work its safe area out again too, which moves the bars back down.
@available(iOS 18.0, *)
private struct SplitBelowTabBar: UIViewRepresentable {
    func makeUIView(context: Context) -> Adjuster { Adjuster() }
    func updateUIView(_ view: Adjuster, context: Context) { view.setNeedsLayout() }

    final class Adjuster: UIView {
        /// The page was asked once since this view came into the window: asked again while the
        /// answer stays the same, laying out would never end.
        private var settled = false
        /// The page is about to be asked for a column under the tab bar, and the times in a row
        /// it was asked to no effect: it is not asked for ever.
        private var asking = false
        private var asked = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            settled = false
            asked = 0
            adjust()
            // Shown or hidden with the sidebar: what it says is settled once that has happened.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.adjust() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            adjust()
        }

        /// Before iOS 26 the sidebar lies over an upright page, and nothing here is laid out as it
        /// opens or folds back; a trait does change with it (not a public one). Without this the
        /// room for the tab bar was taken away by a layout that came while the sidebar was open
        /// (the app going to the background makes one) and not given back when the tab bar
        /// returned. Not at once: sideways the list's column goes and comes back with the
        /// sidebar, which lays this out anyway, and room made before that leaves the list's
        /// buttons a few points off.
        override func traitCollectionDidChange(_ previous: UITraitCollection?) {
            super.traitCollectionDidChange(previous)
            if #available(iOS 26.0, *) { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.adjust() }
        }

        private func adjust() {
            var split: UISplitViewController?
            var tabs: UITabBarController?
            var responder: UIResponder? = self
            while let next = responder {
                if split == nil, let found = next as? UISplitViewController { split = found }
                if let found = next as? UITabBarController { tabs = found; break }
                responder = next.next
            }
            guard let split, let tabs else { return }
            if #available(iOS 26.0, *) {
                var page: UIViewController = split
                while let parent = page.parent, parent !== tabs { page = parent }
                guard page.parent === tabs else { return }
                if #available(iOS 27.0, *) { settle(page, in: tabs) }
                uncover(split, on: page, in: tabs)
                return
            }
            let floating = !tabs.isTabBarHidden && tabs.sidebar.isHidden
                && tabs.traitCollection.horizontalSizeClass == .regular
            let top: CGFloat = floating ? 50 : 0
            if split.additionalSafeAreaInsets.top != top { split.additionalSafeAreaInsets.top = top }
        }

        /// The tab's page, when its safe area still holds the tab bar's height, works it out again.
        private func settle(_ page: UIViewController, in tabs: UITabBarController) {
            guard !settled, page.view.safeAreaInsets.top > tabs.view.safeAreaInsets.top else { return }
            settled = true
            ask(page)
        }

        /// This view's column, found under the tab bar, has the page work its safe area out again.
        /// Not at once: asked while the sidebar is still folding, the page answers the same, and
        /// often the first time after that too. So it is asked a moment later, and again while the
        /// column is still there.
        private func uncover(_ split: UISplitViewController, on page: UIViewController, in tabs: UITabBarController) {
            guard !asking, asked < 20, covered(split, on: page, in: tabs) else { return }
            asking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                // `asking` is still set: the layout this starts does not ask for another.
                if self.covered(split, on: page, in: tabs) { self.ask(page) }
                self.asking = false
                self.asked = self.covered(split, on: page, in: tabs) ? self.asked + 1 : 0
                self.uncover(split, on: page, in: tabs)
            }
        }

        /// The tab bar floats over this view's column: its height is neither in the page's safe
        /// area nor in the column's own.
        private func covered(_ split: UISplitViewController, on page: UIViewController, in tabs: UITabBarController) -> Bool {
            guard window != nil, !tabs.isTabBarHidden, tabs.sidebar.isHidden, tabs.traitCollection.horizontalSizeClass == .regular,
                  page.view.safeAreaInsets.top <= tabs.view.safeAreaInsets.top,
                  let column = split.children.first(where: { isDescendant(of: $0.view) }) else { return false }
            return column.view.safeAreaInsets.top <= split.view.safeAreaInsets.top
        }

        /// A safe area changed and put back is what makes a page work its own out again.
        private func ask(_ page: UIViewController) {
            page.additionalSafeAreaInsets.top += 1
            page.view.layoutIfNeeded()
            page.additionalSafeAreaInsets.top -= 1
            page.view.layoutIfNeeded()
        }
    }
}

extension BotRoute {
    /// `path` as a `NavigationPath` (`MainView.botStackInSplit`).
    fileprivate static func erased(_ path: Binding<[BotRoute]>) -> Binding<NavigationPath> {
        Binding(get: { NavigationPath(path.wrappedValue) }, set: { next in
            let pages = path.wrappedValue
            if next.count <= pages.count {
                path.wrappedValue = Array(pages.prefix(next.count))
            } else if let pushed = routes(in: next) {
                path.wrappedValue = pushed
            }
        })
    }

    /// What a row of the list pushed is read from the path's own encoding, the only way it gives
    /// its pages back: the type's name and the page as JSON for each, the last one first.
    private static func routes(in path: NavigationPath) -> [BotRoute]? {
        guard let codable = path.codable, let data = try? JSONEncoder().encode(codable),
              let fields = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        var routes: [BotRoute] = []
        for index in stride(from: 1, to: fields.count, by: 2) {
            guard let route = try? JSONDecoder().decode(BotRoute.self, from: Data(fields[index].utf8)) else { return nil }
            routes.insert(route, at: 0)
        }
        return routes
    }
}

/// The path of a navigation stack in a split view's detail, handed over once the stack is on
/// screen. Before iOS 18 a stack that first shows there with pages already on its path never
/// finishes that update: the main thread turns inside SwiftUI for good. The app froze as it
/// launched back onto a Bot's chat (and at every launch after), and when a Bot's chat was opened
/// from a conversation (a toast, something shared to a Bot); a window grown wide with a chat
/// open, or a big iPhone turned sideways with one pushed over another, makes a stack the same
/// way. So the stack shows with nothing pushed and takes its pages a moment later, unanimated:
/// they are there as they would have been. From iOS 18 the path is passed as it is.
private struct DetailPath<Route: Hashable, Content: View>: View {
    @Binding var path: [Route]
    @ViewBuilder let content: (Binding<[Route]>) -> Content
    @State private var shown = false

    var body: some View {
        if #available(iOS 18.0, *) {
            content($path)
        } else {
            // Nothing is written back before then: the pages waiting on `path` are not lost.
            content(Binding(get: { shown ? path : [] }, set: { if shown { path = $0 } }))
                .task {
                    var quiet = Transaction()
                    quiet.disablesAnimations = true
                    withTransaction(quiet) { shown = true }
                }
        }
    }
}

/// iPhone Duo held partly open like a book, the sidebar on the near page: the column beside
/// it starts on the far page, so nothing in it is read across the fold. A column the fold
/// cuts down the middle (the sidebar is away) stays whole: half a display would be left empty.
private struct PastTheFold: ViewModifier {
    @State private var inset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, inset)
            .background(Palette.background)
            .onGeometryChange(for: CGFloat.self) { proxy in
                guard let fold = proxy.fold, fold.height > fold.width, fold.midX < proxy.size.width / 2 else { return 0 }
                return max(0, fold.maxX)
            } action: { inset = $0 }
    }
}

/// A navigation stack with a close button, for a list presented on its own.
struct SheetStack<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack { content.closeButton(dismiss) }
    }
}

/// A leftward swipe over the open drawer, reported as it follows the finger. It begins only for
/// a swipe that sets off sideways, to the left, from a point `accepts`: a scroll of the session
/// list never starts it, so nothing here runs while the list scrolls. On the root view, as
/// `DrawerEdgePan` is: pages presented above keep their own gestures.
private struct DrawerClosePan: UIViewRepresentable {
    let enabled: Bool
    /// Whether a swipe that started here (in the window) may close the drawer.
    let accepts: (CGPoint) -> Bool
    let changed: (CGFloat) -> Void
    /// Where the swipe would come to rest; 0 when it was cancelled.
    let ended: (CGFloat) -> Void

    func makeUIView(context: Context) -> Catcher { Catcher() }

    func updateUIView(_ view: Catcher, context: Context) {
        view.enabled = enabled
        view.accepts = accepts
        view.changed = changed
        view.ended = ended
    }

    final class Catcher: UIView, UIGestureRecognizerDelegate {
        var enabled = false
        var accepts: (CGPoint) -> Bool = { _ in true }
        var changed: (CGFloat) -> Void = { _ in }
        var ended: (CGFloat) -> Void = { _ in }
        private lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(panned))
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.rootViewController?.view.addGestureRecognizer(recognizer)
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let view = recognizer.view else { return false }
            let velocity = recognizer.velocity(in: view)
            guard velocity.x < 0, abs(velocity.x) > abs(velocity.y) else { return false }
            let now = recognizer.location(in: view), moved = recognizer.translation(in: view)
            return accepts(CGPoint(x: now.x - moved.x, y: now.y - moved.y))
        }

        /// The list under the finger keeps its own pan; everything else gives way once this one begins.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).x
            switch recognizer.state {
            case .began, .changed: changed(translation)
            case .ended: ended(translation + recognizer.velocity(in: recognizer.view).x * 0.2)
            default: ended(0)
            }
        }
    }
}

/// A swipe from the screen's left edge, reported as it follows the finger. On the root view:
/// sheets above it keep their own edges.
private struct DrawerEdgePan: UIViewRepresentable {
    let enabled: Bool
    let changed: (CGFloat) -> Void
    /// Where the swipe would come to rest; 0 when it was cancelled.
    let ended: (CGFloat) -> Void

    func makeUIView(context: Context) -> Catcher { Catcher() }

    func updateUIView(_ view: Catcher, context: Context) {
        view.enabled = enabled
        view.changed = changed
        view.ended = ended
    }

    final class Catcher: UIView, UIGestureRecognizerDelegate {
        var enabled = true
        var changed: (CGFloat) -> Void = { _ in }
        var ended: (CGFloat) -> Void = { _ in }
        private lazy var recognizer: UIScreenEdgePanGestureRecognizer = {
            let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(panned))
            recognizer.edges = .left
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.rootViewController?.view.addGestureRecognizer(recognizer)
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { enabled }

        @objc private func panned(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).x
            switch recognizer.state {
            case .began, .changed: changed(translation)
            case .ended: ended(translation + recognizer.velocity(in: recognizer.view).x * 0.2)
            default: ended(0)
            }
        }
    }
}

/// The numbers on the tab bar's 会话 and Bot tabs.
struct HomeBadges: Equatable {
    var waiting = 0
    var botPending = 0
}

/// Counts the tab bar's badges and hands `MainView` the numbers, which change far less often than
/// what they are counted from.
private struct HomeBadgeCounter: View {
    @Environment(AppModel.self) private var app
    @Binding var badges: HomeBadges

    var body: some View {
        Color.clear.onChange(of: HomeBadges(waiting: waitingCount, botPending: botPendingCount), initial: true) { _, counts in
            badges = counts
        }
    }

    /// What the 会话 tab's list shows waiting on the user: this phone's conversations and those on
    /// the computers. The Bots' and the groups' sessions are left out, as the list leaves them out:
    /// they count on the Bot tab.
    private var waitingCount: Int {
        let team = app.botTeam
        let teamSessions = team.teamSessionIds
        let local = app.sessions.keys.filter { id in
            app.isWaiting(id) && !app.isArchived(id) && !teamSessions.contains(id)
                && (team.teamWorkspaceId == nil || app.workspace(of: id)?.id != team.teamWorkspaceId)
        }
        let remote = app.remote.signedIn ? app.remote.listed().filter { $0.deviceOnline && $0.waiting }.count : 0
        return local.count + remote
    }

    /// What the Bots wait on the user for, on the Bot tab.
    private var botPendingCount: Int {
        let team = app.botTeam
        return team.bots.reduce(0) { $0 + team.pendingCount(of: $1) }
    }
}
