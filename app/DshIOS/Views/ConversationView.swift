import SwiftUI

/// One conversation: its title and session menu in the top bar, the workbench on
/// the right, the timeline, and the composer. A blank session shows the
/// new-conversation state (model picker on top, headline, workspace chip,
/// suggestions, the large composer).
struct ConversationView: View {
    let sessionId: String
    @Binding var selection: String?
    /// Opens the drawer; nil where the sidebar is always shown (iPad).
    var openDrawer: (() -> Void)?
    /// Start a new conversation in another workspace (the workspace chip).
    var switchWorkspace: (Workspace) -> Void = { _ in }
    /// A Bot's chat or a group chat: its own title in the bar and its cards above the composer.
    var bot: BotChrome?
    /// The global automation page (the reminders sheet leads there).
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The split view's sidebar, as far as the conversation reaches it: room for the workbench, and
    /// (in a Bot's chat, which is pushed and has no drawer button of its own) the sidebar's button.
    @Environment(\.splitSidebar) private var splitSidebar
    @State private var model: SessionModel?
    @State private var context = ComposerContext()
    @State private var workbenchOpen = false
    /// The tab last looked at, in any conversation: the workbench opens where it was left.
    @AppStorage("dsh.workbench.tab") private var workbenchTab = WorkbenchTab.terminal
    /// The browser opened full screen from the chat.
    @State private var fullBrowser: BrowserModel?
    /// Interactions swiped away; they stay answerable from the 「等你允许」 line.
    @State private var deferred: Set<String> = []
    @State private var showNewWorkspace = false
    @State private var jobs = JobsModel()
    @State private var headerSheet: SessionHeaderSheet?
    @State private var presets = AgentPresetCatalog()
    /// The reader is at the end of the timeline, so it follows new output (C-12).
    @State private var atBottom = true
    @State private var showTurns = false
    @State private var timelineTop: CGFloat = 0
    /// What a timeline row opened. Up here, not on the row: a turn that closes folds its rows
    /// and would take the sheet along, and an approval arriving must be able to take over.
    @State private var detail: TimelineDetail?
    /// Approvals seen since none were waiting, for the 「1/3」 of the sheet.
    @State private var approvalBatch: Set<String> = []
    @State private var keyboardUp = false
    @State private var composerFocused = false
    /// The new-conversation page's free height: a short one drops the headline.
    @State private var heroHeight: CGFloat = .infinity
    /// iPhone Duo held partly open like a laptop: where the fold crosses that page.
    @State private var heroFold: CGFloat?
    /// A status or composer sheet is up: approvals and questions present once it has gone
    /// (a second sheet can't stack on it, and one that failed to show would be lost).
    @State private var inputSheetUp = false
    #if DEBUG
    @State private var demoApproval: PendingApproval?
    @State private var demoQuestion: PendingQuestion?
    #endif

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ConversationLoading().background(Palette.background)
            }
        }
        .task {
            // A child opens by its parent's address, which the list knows.
            if app.sessions[sessionId] == nil { await app.refreshSessions() }
            // Kept from the last time it was open, it shows at once and catches up behind.
            let app = self.app, sessionId = self.sessionId
            let session = app.localSessions.acquire(sessionId) {
                let session = SessionModel(sessionId: sessionId, app: app)
                session.subagentAddress = app.subagentAddress(for: sessionId)
                return session
            }
            session.modelCatalog = context
            model = session
            await context.load(session)
        }
        .task(id: "\(sessionId)-\(app.generation)") { await jobs.follow(sessionId: sessionId, app: app) }
        .task(id: app.generation) { await presets.load(app.client) }
        .onDisappear {
            guard model != nil else { return }
            app.localSessions.release(sessionId)
        }
        .trackKeyboard($keyboardUp)
        // A key saved or an account signed in changes what the model picker can offer.
        .task(id: app.revision("llm/adapters-updated", "settings/document-updated", "credentials/reference-updated", "credentials/record-updated")) {
            if let model { await context.load(model) }
        }
        #if DEBUG
        .task {
            switch UserDefaults.standard.string(forKey: "dshOpen") {
            case "workbench": workbenchOpen = true
            case "approval": demoApproval = PendingApproval(id: "demo", toolName: "bash", callId: nil, reason: "允许本次操作使用 danger-full-access 权限：当前处于 workspace-write 模式，写不到工作区以外。这条命令会删除 build/ 下约 1.4 GB 的文件，再重新下载依赖，失败时不会自动恢复，需要手动重新构建一次才能继续。")
            case "question":
                // `-dshDelay <s>` leaves time to focus the composer first.
                try? await Task.sleep(for: .seconds(UserDefaults.standard.double(forKey: "dshDelay") + 1))
                demoQuestion = PendingQuestion(QuestionRequest(eventId: "demo", request: [
                    "questions": [[
                        "id": "q", "header": "抖音需要登录",
                        "question": "抖音网页版现在不给未登录用户看搜索结果（页面直接弹「登录后即可搜索更多精彩视频」，手机版还跳验证码）。搜索得先登录，这一步只能你来做。你想怎么办？",
                        "options": [
                            ["label": "我来登录，你接着搜 (推荐)", "description": "在右边的浏览器里扫码或用验证码登录，登录好告诉我。"],
                            ["label": "改看精选页", "description": "精选页（/jingxuan）不登录也能看，但那是频道推荐流，不是搜索结果的第 2 页。"],
                            ["label": "换一个平台搜，比如 B 站或小红书", "description": "离开抖音，用不需要登录的站完成「搜索 + 第 2 页」这件事。"],
                        ],
                    ]],
                ]))
            case "timeline":
                try? await Task.sleep(for: .seconds(2))
                model?.debugLoadFixture(TimelineFixture.events)
            default: break
            }
        }
        .sheet(item: $demoApproval) { approval in
            ApprovalSheet(approval: approval, call: ToolCall(id: "demo", name: "bash", arguments: ["command": .string((1...30).map { "rm -rf build/cache-\($0)" }.joined(separator: " &&\n"))], rawArguments: ""), position: (1, 3)) { _ in demoApproval = nil }
        }
        .sheet(item: $demoQuestion) { question in
            if let model { QuestionSheet(model: model, question: question) }
        }
        #endif
    }

    private static let bottomId = "timeline-bottom"

    /// On the next pass, once the new rows have their heights.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        Task { @MainActor in
            if animated {
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
        }
    }

    private func isBlank(_ model: SessionModel) -> Bool {
        bot == nil && model.subagentAddress == nil && model.loaded && model.items.isEmpty && model.live.isEmpty && !model.running
    }

    @ViewBuilder
    private func content(_ model: SessionModel) -> some View {
        let blank = isBlank(model)
        // A conversation that has started: the bar carries its title menu, not the model picker.
        let started = !blank && model.subagentAddress == nil && !(!model.loaded && app.sessions[sessionId]?.blank == true)
        ScrollViewReader { proxy in
            ScrollView {
                TimelineList(model: model)
                    .modifier(LinkOpening())
                // Room for the floating chips, so they never sit on the last row.
                Color.clear.frame(height: activityShown(blank) ? 48 : 1).id(Self.bottomId)
            }
            // Until the first read answers; a conversation known to be blank shows its own start.
            // The fade is the overlay's alone: animating the timeline's arrival would carry it past
            // the bottom anchor, and the page would open above the last message.
            .overlay {
                ZStack {
                    if !model.loaded && app.sessions[sessionId]?.blank != true {
                        ConversationLoading().transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: model.loaded)
            }
            // The first read in: open at the last message.
            .onChange(of: model.loaded) { _, loaded in
                if loaded { atBottom = true; scrollToBottom(proxy, animated: false) }
            }
            .environment(\.timelineScroll, TimelineScroll(keep: { id in
                Task { @MainActor in
                    // The rows above have to be laid out before their height can be kept.
                    try? await Task.sleep(for: .milliseconds(60))
                    proxy.scrollTo(id, anchor: .top)
                }
            }, top: timelineTop))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { timelineTop = $0 }
            .modifier(TimelineAnchor())
            .modifier(BottomFollow(atBottom: $atBottom) { scrollToBottom(proxy, animated: false) })
            // Any drag on the timeline hides the keyboard (`.interactively` only does when the finger reaches it),
            // even when the timeline is too short to scroll; so does a tap outside the composer.
            .scrollDismissesKeyboard(.immediately)
            .scrollBounceBehavior(.always)
            // A moment later, not at once: the keyboard going moves the rows, and a link under the
            // finger would lose the tap; it opens first, and the keyboard goes after.
            .simultaneousGesture(TapGesture().onEnded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { dismissKeyboard() }
            })
            // The bottom anchor only holds for the first layout; follow the user's own message and the start of a turn.
            .onChange(of: model.items.last?.id) { _, _ in
                if case .user? = model.items.last { atBottom = true; scrollToBottom(proxy) }
            }
            .onChange(of: model.running) { _, running in if running, atBottom { scrollToBottom(proxy) } }
            .overlay(alignment: .bottomTrailing) {
                // Animated here, not on the scroll view: its rows must not animate with the buttons.
                ZStack {
                    if !atBottom && !blank {
                        VStack(spacing: 8) {
                            // The web's turn rail needs a wide window; here it is a list one tap away.
                            if model.turnOutline.count >= 2 {
                                FloatingIcon(systemName: "list.bullet", label: "跳转到轮次") { showTurns = true }
                            }
                            FloatingIcon(systemName: "chevron.down", label: "回到底部") {
                                atBottom = true
                                scrollToBottom(proxy)
                            }
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .animation(.snappy(duration: 0.18), value: atBottom)
            }
            // Opposite the scroll buttons: the agent's page and its background jobs, one tap from the chat.
            .overlay(alignment: .bottomLeading) {
                if !blank && hasTools {
                    ConversationActivity(
                        sessionId: sessionId, jobs: jobs,
                        browserShown: browserBeside,
                        openBrowser: openBrowser,
                        openJobs: { headerSheet = .jobs }
                    )
                    .padding(.leading, 16)
                    .padding(.bottom, 12)
                }
            }
            .sheet(isPresented: $showTurns) {
                TurnJumpSheet(outline: model.turnOutline) { entry in
                    showTurns = false
                    Task {
                        if let anchor = await model.anchor(of: entry) {
                            try? await Task.sleep(for: .milliseconds(120))
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    }
                }
            }
        }
        .background(Palette.background)
        .overlay { if blank { hero(model) } }
        .conversationDock {
            VStack(alignment: .leading, spacing: 0) {
                if blank && !composerFocused && model.composer.isEmpty {
                    suggestions(model).padding(.bottom, 10)
                }
                if let accessory = bot?.accessory { accessory.padding(.bottom, 8) }
                ComposerStatusBar(
                    model: model, keyboardUp: keyboardUp,
                    waiting: waitingInteraction(model).map { $0.isApproval ? String(localized: "等你允许") : String(localized: "等你回答") },
                    reveal: { if let waiting = waitingInteraction(model) { deferred.remove(waiting.id) } },
                    interactionArrived: interactions(model).contains { !deferred.contains($0.id) },
                    sheetUp: $inputSheetUp
                )
                if let notice = model.subagentReadOnly(parentAvailable: parentAvailable(model)) {
                    SubagentReadOnlyNotice(title: notice.title, detail: notice.detail)
                } else {
                    ComposerView(
                        model: model, context: context, pendingDraft: app.pendingDrafts[sessionId],
                        consumeDraft: { app.pendingDrafts[sessionId] = nil },
                        pendingFiles: app.pendingFiles[sessionId],
                        consumeFiles: { app.pendingFiles[sessionId] = nil },
                        pendingPrompt: app.pendingPrompts[sessionId],
                        consumePrompt: { app.pendingPrompts[sessionId] = nil },
                        focusOnAppear: app.pendingFocus.contains(sessionId),
                        consumeFocus: { app.pendingFocus.remove(sessionId) },
                        openLogExport: { headerSheet = .logExport },
                        focusChanged: { composerFocused = $0 },
                        sheetUp: $inputSheetUp
                    )
                    .allowsHitTesting(presentedInteractionId(model) == nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .readableWidth()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { app.composerHeight = $0 }
        }
        .modifier(ComposerDrop(composer: model.composer, enabled: model.subagentReadOnly(parentAvailable: parentAvailable(model)) == nil))
        // Under the toolbar: what is inside an inspector's main view does not reach the navigation bar.
        .modifier(WorkbenchBeside(shown: workbenchShown(sizeClass == .regular), regular: sizeClass == .regular) {
            workbenchPage(model)
        })
        // It names the window in the iPad app switcher. Not drawn while the title is the principal
        // item; with the title moved aside for the workbench it would show as a second one.
        .navigationTitle(titleBesideWorkbench ? "" : app.durableTitle(of: sessionId) ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .conversationBar()
        // Stated, not left to the default: the workbench's files and changes hide the bar of
        // their own stacks, and without this closing the sheet takes this bar along.
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if let openDrawer = openDrawer ?? splitSidebar.toggle {
                ToolbarItem(placement: .topBarLeading) { DrawerButton(action: openDrawer) }
            }
            if let bot {
                // Beside the bar's leading buttons the bar gives an item only what it asks for:
                // without this the name is squeezed out and only the avatar is left.
                ToolbarItem(placement: titlePlacement) { bot.title.fixedSize(horizontal: titleBesideWorkbench, vertical: false) }
            }
            // As the web keeps 新会话 in its sidebar, the bar keeps it one tap away: no drawer
            // first. A blank conversation is already a new one, so it only shows on a started one.
            if started && bot == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        app.newSessionRequest = NewSessionRequest(workspaceId: app.workspace(of: sessionId)?.id)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新会话")
                }
            }
            // A Bot's chat has the Bot's own title instead of the session's.
            if bot == nil {
                if let parent = app.sessions[sessionId]?.parentId, model.subagentAddress != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { app.open(session: parent) } label: { Image(systemName: "chevron.backward") }
                            .accessibilityLabel("返回父会话")
                    }
                    ToolbarItem(placement: titlePlacement) { SubagentSwitcher(sessionId: sessionId) }
                } else if blank || (!model.loaded && app.sessions[sessionId]?.blank == true) {
                    ToolbarItem(placement: .principal) { ModelPicker(model: model, context: context) }
                } else {
                    ToolbarItem(placement: titlePlacement) {
                        SessionTitleMenu(
                            // 新会话 sits beside the drawer button on every started conversation,
                            // so on a phone the title always makes room for it.
                            sessionId: sessionId, streamTitle: model.title, catalog: presets, crowded: true
                        ) { headerSheet = .logExport }
                    }
                }
            }
            if !blank {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // A Bot runs no subagents of DSH's, its scheduled tasks are on its own page, and
                    // its background jobs float over the chat's foot.
                    if bot == nil { SessionHeaderActions(sessionId: sessionId) { headerSheet = $0 } }
                    if let menu = bot?.menu {
                        menu(model, hasTools ? BotChatTools(toggleWorkbench: toggleWorkbench, openBrowser: openBrowser) : nil)
                    }
                    // A Bot's chat keeps its bar to the title and its menu: the workbench is in the menu.
                    if bot == nil {
                        Button(action: toggleWorkbench) { Image(systemName: "apple.terminal") }
                            .accessibilityLabel("工作台")
                    }
                }
            }
        }
        .environment(\.conversationActions, ConversationActions(
            openChanges: { openWorkbench(.changes) },
            openBrowser: openBrowser,
            regenerate: { text in Task { await model.send(text: text) } },
            fork: { turn in
                Task { await app.fork(session: sessionId, atSeq: model.forkBoundary(turn: turn), from: .turn) }
            },
            quote: { text in
                let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).map { "> \($0)" }.joined(separator: "\n")
                let draft = model.composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                model.composer.text = quoted + "\n\n" + draft
                Haptics.tap()
            },
            revealQuestion: { deferred.remove("q-\($0)") },
            present: { item in
                // The timeline stays usable behind an approval: what is waiting steps aside, one tap away.
                deferred.formUnion(interactions(model).map(\.id))
                detail = item
            }
        ))
        // Over the conversation on a phone, beside it where there is room.
        .sheet(isPresented: workbenchShown(sizeClass != .regular)) {
            workbenchPage(model)
                .presentationDetents([.large])
                .presentationCornerRadius(36)
                // A pull over the terminal is meant for its scrollback; ✕ closes the sheet.
                .interactiveDismissDisabled(workbenchTab == .terminal)
        }
        .fullScreenCover(isPresented: Binding(get: { fullBrowser != nil }, set: { if !$0 { fullBrowser = nil } })) {
            if let fullBrowser { FullScreenBrowser(model: fullBrowser) { self.fullBrowser = nil } }
        }
        .onChange(of: workbenchOpen) { _, open in if open, sizeClass == .regular { splitSidebar.makeRoom() } }
        .focusedSceneValue(\.workbenchCommands, WorkbenchCommands(available: !blank && hasTools, toggle: toggleWorkbench, open: openWorkbench))
        // The sheet leaves the background live, so the composer keeps its focus and the
        // keyboard would stay over the sheet; an answer comes first.
        .onChange(of: presentedInteractionId(model)) { _, id in if id != nil { dismissKeyboard() } }
        // An approval or question arriving: the one alert-like tap (as the web's warning tone).
        .onChange(of: waitingInteraction(model)?.id) { old, new in
            if let new, new != old { Haptics.warning() }
        }
        .onChange(of: pendingApprovalIds, initial: true) { _, ids in
            if ids.isEmpty { approvalBatch = [] } else { approvalBatch.formUnion(ids) }
        }
        .task(id: app.questionRequests[sessionId]?.map(\.eventId)) { model.syncQuestionWaits() }
        .sheet(item: interactionBinding(model)) { sheet(for: $0, model) }
        .sheet(isPresented: $showNewWorkspace) { NewWorkspaceView() }
        .sheet(item: $headerSheet) { sheet in
            Group {
                switch sheet {
                case .subagents: SubagentCatalogSheet(rootId: sessionId)
                case .jobs: JobsSheet(sessionId: sessionId, jobs: jobs)
                case .reminders:
                    SheetStack {
                        SchedulesView(sessionId: sessionId) { id in
                            headerSheet = nil
                            selection = id
                        }
                    }
                    .environment(\.systemLists, true)
                case .logExport: SessionLogExportSheet(sessionId: sessionId)
                }
            }
            .sheetNotices()
        }
        .alert("出错了", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
        .environment(\.fileLinkScope, FileLinkScope(sessionId: sessionId, root: model.workingDirectory))
        .environment(\.browserLinks, BrowserLinks(
            sessionId: BrowserAgent.owner(of: sessionId, in: app), origin: app.client.origin, beside: browserBeside))
        .environment(\.sessionModel, model)
    }

    // MARK: Workbench

    /// The bar runs over the workbench too: centred, the title would sit on the column's edge.
    private var titlePlacement: ToolbarItemPlacement {
        titleBesideWorkbench ? .topBarLeading : .principal
    }

    private var titleBesideWorkbench: Bool { sizeClass == .regular && workbenchOpen }

    /// The workbench's browser is already on screen beside the conversation.
    private var browserBeside: Bool { sizeClass == .regular && workbenchOpen && workbenchTab == .browser }

    /// The conversation's tools (workbench, browser, background jobs) are reachable here: DSH's own
    /// conversations and a Bot's chat, not a group's session.
    private var hasTools: Bool { bot?.tools ?? true }

    private func activityShown(_ blank: Bool) -> Bool {
        !blank && hasTools && ConversationActivity.shows(sessionId: sessionId, jobs: jobs, browserShown: browserBeside, in: app)
    }

    /// From the chat the browser opens full screen, the page alone: the workbench's other tabs are not
    /// what the user came for. A subagent's page is its parent conversation's.
    private func openBrowser() {
        dismissKeyboard()
        fullBrowser = BrowserModel.session(BrowserAgent.owner(of: sessionId, in: app), origin: app.client.origin)
    }

    private func openWorkbench(_ tab: WorkbenchTab) {
        workbenchTab = tab
        workbenchOpen = true
    }

    private func toggleWorkbench() {
        workbenchOpen.toggle()
    }

    /// One state, shown in whichever place the width calls for.
    private func workbenchShown(_ here: Bool) -> Binding<Bool> {
        Binding(get: { here && workbenchOpen }, set: { if !$0 { workbenchOpen = false } })
    }

    private func workbenchPage(_ model: SessionModel) -> some View {
        WorkbenchView(model: model, tab: $workbenchTab) { workbenchOpen = false }
    }

    /// A continuable child takes messages only through a live parent Agent.
    private func parentAvailable(_ model: SessionModel) -> Bool {
        guard let parent = model.subagentAddress?["parentSessionId"].string else { return true }
        return app.sessions[parent]?.agentAvailable ?? false
    }

    // MARK: New conversation

    private func hero(_ model: SessionModel) -> some View {
        let showsHeadline = !keyboardUp && min(heroHeight, heroFold ?? .infinity) >= 220
        return VStack(spacing: 14) {
            if showsHeadline {
                // The web's headline (`conversation.hero.headline`), so both shells greet the same way.
                Text("探索未至之境").font(.system(size: 34, weight: .bold)).foregroundStyle(Palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
            }
            // Side by side while both fit; a narrow window (iPhone Duo closed, Split View) stacks them
            // instead of folding a name onto two lines.
            RowOrColumn(spacing: 8) {
                Menu {
                    Section("工作区") {
                        ForEach(app.workspaces) { workspace in
                            Button { if workspace.id != app.workspace(of: sessionId)?.id { switchWorkspace(workspace) } } label: {
                                if workspace.id == app.workspace(of: sessionId)?.id { Label(workspace.displayTitle, systemImage: "checkmark") } else { Text(workspace.displayTitle) }
                            }
                        }
                    }
                    Button { showNewWorkspace = true } label: { Label("添加工作区", systemImage: "folder.badge.plus") }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(Palette.secondary)
                        Text(app.workspace(of: sessionId)?.displayTitle ?? String(localized: "选择工作区")).foregroundStyle(Palette.ink).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Palette.secondary)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Palette.field, in: Capsule())
                    .hitTarget()
                }
                .accessibilityLabel(Text("工作区：\(app.workspace(of: sessionId)?.displayTitle ?? "")"))
                AgentPresetChip(sessionId: sessionId, catalog: presets)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        // Centred in what is above the fold, when there is one.
        .frame(maxWidth: .infinity, maxHeight: heroFold ?? .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heroHeight = $0 }
        .onGeometryChange(for: CGFloat?.self) { proxy in
            proxy.fold.flatMap { $0.width > $0.height ? $0.minY : nil }
        } action: { heroFold = $0 }
        .animation(.snappy(duration: 0.2), value: showsHeadline)
    }

    /// Starter prompts; a tap fills the input, to send as is or to change first.
    private func suggestions(_ model: SessionModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    Haptics.tap()
                    app.pluginStoreRequest = UUID()
                } label: {
                    Label("发现插件", systemImage: "puzzlepiece.extension")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.onInk)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(Palette.ink, in: Capsule())
                        .hitTarget()
                }
                ForEach(Self.suggestions, id: \.self) { text in
                    Button {
                        Haptics.tap()
                        model.composer.text = text
                        model.composer.requestFocus()
                    } label: {
                        Text(text).font(.subheadline).foregroundStyle(Palette.ink.opacity(0.85))
                            .padding(.horizontal, 16)
                            .frame(minHeight: 40)
                            .overlay(Capsule().strokeBorder(Palette.control))
                            .hitTarget()
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollClipDisabled()
    }

    private static var suggestions: [String] {
        [String(localized: "看看这个工作区里有什么"), String(localized: "写一个小脚本并运行"), String(localized: "解释一段代码"), String(localized: "整理今天的待办")]
    }

    // MARK: Approvals and questions

    enum Interaction: Identifiable {
        case approval(PendingApproval)
        case question(PendingQuestion)
        /// Not waiting for anyone, but it shares the one sheet: an approval takes its place, and it comes back after.
        case detail(TimelineDetail)
        var id: String {
            switch self {
            case .approval(let approval): "a-\(approval.id)"
            case .question(let question): "q-\(question.id)"
            case .detail(let detail): "d-\(detail.id)"
            }
        }
        var isApproval: Bool { if case .approval = self { true } else { false } }
    }

    /// Approvals before questions, oldest first, as the web composer takeover orders them.
    private func presentedInteractionId(_ model: SessionModel) -> String? {
        interactions(model).first { !deferred.contains($0.id) }?.id
    }

    private func interactions(_ model: SessionModel) -> [Interaction] {
        (app.approvals[sessionId] ?? []).map(Interaction.approval) + model.questions.map(Interaction.question)
    }

    private func waitingInteraction(_ model: SessionModel) -> Interaction? {
        interactions(model).first { deferred.contains($0.id) }
    }

    private func interactionBinding(_ model: SessionModel) -> Binding<Interaction?> {
        Binding(
            get: { inputSheetUp ? nil : interactions(model).first { !deferred.contains($0.id) } ?? detail.map(Interaction.detail) },
            set: { value in
                guard value == nil else { return }
                // Swiped away while still pending: keep it behind the 「等你允许」 line.
                if let shown = interactions(model).first(where: { !deferred.contains($0.id) }) { deferred.insert(shown.id) } else { detail = nil }
            }
        )
    }

    @ViewBuilder
    private func sheet(for interaction: Interaction, _ model: SessionModel) -> some View {
        switch interaction {
        case .approval(let approval):
            ApprovalSheet(approval: approval, call: model.toolCall(approval.callId), position: approvalPosition(approval)) { allow in
                Task { await app.answerApproval(approval, session: sessionId, allow: allow) }
            }
        case .question(let question):
            if let review = question.planReview {
                PlanReviewSheet(model: model, question: question, review: review)
            } else {
                QuestionSheet(model: model, question: question)
            }
        case .detail(.tool(let call)):
            ToolDetailSheet(call: call, model: model)
        case .detail(.reasoning(let id, let text)):
            ReasoningSheet(id: id, text: text, model: model)
        case .detail(.usage(let usage)):
            TurnUsageSheet(usage: usage)
        case .detail(.text(let text)):
            SelectTextSheet(text: text)
        }
    }

    private var pendingApprovalIds: [String] { (app.approvals[sessionId] ?? []).map(\.id) }

    /// Counts up through the batch: an answered approval still counts, so 「1/3」 moves on to 「2/3」.
    private func approvalPosition(_ approval: PendingApproval) -> (current: Int, total: Int)? {
        let pending = pendingApprovalIds
        let total = max(approvalBatch.count, pending.count)
        guard total > 1, let index = pending.firstIndex(of: approval.id) else { return nil }
        return (total - pending.count + index + 1, total)
    }
}

/// Keeps the timeline at its end while the reader is there (C-12): within 25 pt of the
/// bottom counts as following, and growth then scrolls along; scrolling up lets go.
/// iOS 17 has no scroll geometry: the view stays where the anchor leaves it.
/// A long timeline opens at its end and grows from there; a short one sits at the top.
/// iOS 17 has only the one anchor, so a short timeline sits at the bottom there.
struct TimelineAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

struct BottomFollow: ViewModifier {
    @Binding var atBottom: Bool
    let follow: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Metrics.self) { geometry in
                // `containerSize` already leaves the insets out; the visible rect runs under them.
                Metrics(
                    contentHeight: geometry.contentSize.height,
                    distance: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
                )
            } action: { old, new in
                if new.contentHeight > old.contentHeight, old.distance <= Self.threshold {
                    follow()
                } else {
                    atBottom = new.distance <= Self.threshold
                }
            }
        } else {
            content
        }
    }

    private static let threshold: CGFloat = 25

    private struct Metrics: Equatable {
        var contentHeight: CGFloat
        var distance: CGFloat
    }
}

/// Lets a row keep the reader's place after the rows above it change.
struct TimelineScroll {
    var keep: (String) -> Void = { _ in }
    /// Where the visible timeline starts on screen, below the top bar.
    var top: CGFloat = 0
}

extension EnvironmentValues {
    /// Set by the split view: what a conversation in its detail can do with the sidebar.
    @Entry var splitSidebar = SplitSidebar()
    @Entry var timelineScroll = TimelineScroll()
    /// The user's own messages in a Bot's chat, in the Bot's colour; nil keeps the plain bubble.
    @Entry var userBubbleTint: BubbleTint?
}

/// A bubble's fill and the text that reads on it.
struct BubbleTint: Equatable {
    var fill: Color
    var text: Color
}

/// The user's side of a chat, one look wherever a message of theirs shows: what they typed, an
/// answer to a question card, an earlier part of a Bot's chat, a word added to a group's round.
/// In a Bot's chat it takes the colour the Bot was given (`userBubbleTint`).
private struct UserBubbleStyle: ViewModifier {
    @Environment(\.userBubbleTint) private var tint

    func body(content: Content) -> some View {
        content
            // `.primary` is the inherited style: a plain bubble stays as it was.
            .foregroundStyle(tint.map { AnyShapeStyle($0.text) } ?? AnyShapeStyle(.primary))
            .background(tint?.fill ?? Palette.bubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

extension View {
    /// A message of the user's (`UserBubbleStyle`); the padding is the caller's.
    func userBubble() -> some View { modifier(UserBubbleStyle()) }
}

/// Actions a reply offers below it, provided by the conversation.
struct ConversationActions {
    var openChanges: () -> Void = {}
    /// The workbench's browser, which the agent's browser tool drives.
    var openBrowser: () -> Void = {}
    var regenerate: (String) -> Void = { _ in }
    var fork: (Int) -> Void = { _ in }
    /// Quote a reply into the composer, to answer that part of it.
    var quote: (String) -> Void = { _ in }
    /// Bring a question swiped away back up, from its tool row.
    var revealQuestion: (String) -> Void = { _ in }
    /// Open what a row holds in the conversation's sheet.
    var present: (TimelineDetail) -> Void = { _ in }
}

/// What a row of the timeline opens.
enum TimelineDetail: Identifiable {
    case tool(ToolCall)
    case reasoning(id: String, text: String)
    case usage(TurnUsage)
    case text(String)

    var id: String {
        switch self {
        case .tool(let call): "tool-\(call.id)"
        case .reasoning(let id, _): "reasoning-\(id)"
        case .usage: "usage"
        case .text: "text"
        }
    }
}

extension EnvironmentValues {
    @Entry var conversationActions = ConversationActions()
}

extension SessionModel {
    /// The tool call an approval is about, to show its command or path.
    func toolCall(_ callId: String?) -> ToolCall? {
        guard let callId else { return nil }
        for block in live.reversed() { if case .tool(let call) = block, call.id == callId { return call } }
        for item in items.reversed() {
            guard case .assistant(_, let blocks, _, _) = item else { continue }
            for block in blocks.reversed() { if case .tool(let call) = block, call.id == callId { return call } }
        }
        return nil
    }

    /// A reasoning block's text as it stands now, so an open sheet follows the stream.
    func reasoningText(_ id: String) -> String? {
        for block in live { if case .reasoning(id, let text) = block { return text } }
        for item in items.reversed() {
            guard case .assistant(_, let blocks, _, _) = item else { continue }
            for block in blocks { if case .reasoning(id, let text) = block { return text } }
        }
        return nil
    }
}

/// Its views in a row at their natural width when that fits, else one above the other, centred.
private struct RowOrColumn: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = measure(subviews, width: proposal.width)
        let gaps = spacing * CGFloat(max(0, sizes.items.count - 1))
        if sizes.row {
            return CGSize(width: sizes.items.map(\.width).reduce(0, +) + gaps, height: sizes.items.map(\.height).max() ?? 0)
        }
        return CGSize(width: sizes.items.map(\.width).max() ?? 0, height: sizes.items.map(\.height).reduce(0, +) + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(subviews, width: bounds.width)
        for index in subviews.indices where !sizes.indices.contains(index) {
            subviews[index].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .zero)
        }
        var x = bounds.minX, y = bounds.minY
        for (index, size) in zip(sizes.indices, sizes.items) {
            let origin = sizes.row
                ? CGPoint(x: x, y: bounds.midY - size.height / 2)
                : CGPoint(x: bounds.midX - size.width / 2, y: y)
            subviews[index].place(at: origin, proposal: ProposedViewSize(size))
            x += size.width + spacing
            y += size.height + spacing
        }
    }

    /// Views with nothing to show (a chip with no options yet) take no space and no gap.
    private func measure(_ subviews: Subviews, width: CGFloat?) -> (row: Bool, indices: [Int], items: [CGSize]) {
        let natural = subviews.map { $0.sizeThatFits(.unspecified) }
        let indices = natural.indices.filter { natural[$0].width > 0 }
        let rowWidth = indices.map { natural[$0].width }.reduce(0, +) + spacing * CGFloat(max(0, indices.count - 1))
        if rowWidth <= (width ?? .infinity) { return (true, indices, indices.map { natural[$0] }) }
        return (false, indices, indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)) })
    }
}

/// The timeline. Its own view so that projection and session-list updates, which
/// redraw `ConversationView`, do not re-diff every row.
private struct TimelineList: View {
    let model: SessionModel
    @Environment(\.botTimeline) private var bot
    @Environment(\.botComposer) private var botChat

    var body: some View {
        // A Bot's chat leaves out the turns that answered another Bot (ds-bot draws none of them).
        let items = bot.map { bot in model.items.filter { !bot.hides($0) } } ?? model.items
        let lastAssistant = items.last { if case .assistant = $0 { true } else { false } }?.id
        // The turn being worked on: the streamed attempt joins it, under one step line (as the web does).
        // A turn that has ended is not it: right after a send the session already runs while the new
        // message is still on its way, and the last reply would open up as if it were being written.
        let activeTurn: String? = if model.running, case .assistant(_, _, _, nil)? = items.last { items.last?.id } else { nil }
        // Not lazy: a lazy stack estimates the heights of rows it has not laid out, and when a long
        // timeline grows the estimate leaves the bottom-anchored viewport past the real end (a blank page
        // after sending). The snapshot holds only the recent history and rows skip unchanged redraws.
        VStack(alignment: .leading, spacing: 20) {
            if model.hasMoreHistory { LoadOlderTrigger(model: model) }
            // A Bot's chat moves to a fresh part when it grows long; the earlier parts come from ds-bot.
            if !model.hasMoreHistory, model.loaded, let from = bot?.earlierFrom { BotEarlierParts(sessionId: from) }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if bot?.room == true, case .assistant(_, let blocks, _, _) = item, let relay = RoomRelay(blocks: blocks) {
                    // A group round: its members' replies, under their names.
                    if !relay.empty { RoomRelayView(relay: relay, running: item.id == activeTurn).id(item.id) }
                } else if bot?.room == true, case .trigger(let trigger) = item, trigger.post {
                    // A Bot's post into the group: a message of the group, unless its round shows it already.
                    if !trigger.postShown { RoomPostView(trigger: trigger).id(item.id) }
                } else if item.id == activeTurn, case .assistant(let turn, let blocks, let started, _) = item {
                    ActiveTurn(model: model, turn: turn, blocks: blocks, startedAt: started)
                } else {
                    let isLast = item.id == lastAssistant
                    TimelineRow(
                        item: item,
                        model: model,
                        isLast: isLast,
                        inProgress: false,
                        prompt: isLast ? Self.prompt(before: index, in: items) : nil,
                        info: Self.turn(of: item).flatMap { model.turnInfo[$0] },
                        arrives: arrives(item)
                    )
                    .equatable()
                    .id(item.id)
                }
            }
            // A message just sent comes first, then the line saying the reply is on its way: until the
            // engine's copy of the message is in, the turn's loading line waits.
            let sending = model.composer.pending.contains { $0.placement == .transcript }
            if model.running && !sending && activeTurn == nil && bot?.room != true { LiveSection(model: model) }
            // A group round says who is speaking in its own place; a Bot's own chat shows the Bot at work.
            if model.running && !sending && bot?.room != true {
                if case .bot(let id)? = botChat { BotActivityLine(botId: id, model: model) } else { RunningIndicator(since: model.runningSince) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .readableWidth()
    }

    /// A message sent while the conversation is open rises into place; what a snapshot brought
    /// (opening it, a kept one catching up, a reconnect) is already there.
    private func arrives(_ item: TimelineItem) -> Bool {
        guard model.loaded, case .user(let seq, _, _, _) = item else { return false }
        return seq > model.snapshotThrough
    }

    private static func turn(of item: TimelineItem) -> Int? {
        if case .assistant(let turn, _, _, _) = item { return turn }
        return nil
    }

    /// The user message a reply answers, for 「重新生成」.
    private static func prompt(before index: Int, in items: [TimelineItem]) -> String? {
        for item in items[..<index].reversed() {
            if case .user(_, let text, _, _) = item, !text.isEmpty { return text }
        }
        return nil
    }
}

/// The turn being worked on, with the streamed attempt appended. Only this view
/// and `LiveSection` observe `live`, so a chunk does not redraw the rest of the timeline.
private struct ActiveTurn: View {
    let model: SessionModel
    let turn: Int
    let blocks: [AssistantBlock]
    let startedAt: Date?
    @Environment(\.botComposer) private var botChat

    var body: some View {
        let live = shownLive(model.live, botChat: botChat)
        AssistantTurnView(blocks: blocks + live, turn: turn, inProgress: true, liveCount: live.count, startedAt: startedAt, endedAt: nil, info: model.turnInfo[turn])
    }
}

/// What of the streamed attempt shows. A Bot's own chat reads like a message from a person: its words
/// arrive whole, once written, and until then the Bot's line below says it is typing.
private func shownLive(_ live: [AssistantBlock], botChat: BotComposer?) -> [AssistantBlock] {
    guard case .bot? = botChat else { return live }
    return live.filter { if case .text = $0 { false } else { true } }
}

/// A running session before its turn has a durable message: the streamed attempt,
/// or just the step line (「正在分析请求」).
private struct LiveSection: View {
    let model: SessionModel
    @Environment(\.botComposer) private var botChat

    var body: some View {
        let live = shownLive(model.live, botChat: botChat)
        // In a Bot's own chat the Bot's mark below is the loading line.
        if case .bot? = botChat, live.isEmpty {} else {
            AssistantTurnView(blocks: live, turn: nil, inProgress: true, liveCount: live.count, startedAt: nil, endedAt: nil)
        }
    }
}

/// Rows compare by value: rebuilding one with an unchanged item is skipped.
private struct TimelineRow: View, Equatable {
    let item: TimelineItem
    let model: SessionModel
    let isLast: Bool
    let inProgress: Bool
    let prompt: String?
    let info: TurnInfo?
    var arrives = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.model === rhs.model && lhs.isLast == rhs.isLast && lhs.inProgress == rhs.inProgress
            && lhs.prompt == rhs.prompt && lhs.info == rhs.info && lhs.arrives == rhs.arrives
    }

    var body: some View {
        switch item {
        case .user(_, let text, let attachments, let requestId):
            UserBubble(text: text, attachments: attachments, model: model, via: IMPlatform.via(requestId), arrives: arrives)
        case .assistant(let turn, let blocks, let started, let ended):
            AssistantTurnView(blocks: blocks, turn: turn, inProgress: inProgress, startedAt: started, endedAt: ended, regeneratePrompt: inProgress ? nil : prompt, info: info)
        case .notice(_, let text, let isError):
            Label(text, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.footnote)
                .foregroundStyle(isError ? Palette.removed : Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .maxTokens:
            MaxTokensNotice(model: model)
        case .credential(_, let problem):
            CredentialNotice(id: item.id, problem: problem, model: model)
        case .questionReply(let reply):
            QuestionReplyBubble(reply: reply)
        case .trigger(let trigger):
            TriggerNotice(trigger: trigger)
        case .command(let command):
            CommandCard(command: command)
        case .compaction(let card):
            CompactionNotice(card: card)
        case .retry(let retry):
            RetryNotice(retry: retry)
        }
    }
}

struct FloatingIcon: View {
    let systemName: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 40, height: 40)
                .background(Palette.background, in: Circle())
                .overlay(Circle().strokeBorder(Palette.stroke))
                .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The turns of this session, newest last; tapping one scrolls to it (C-14).
private struct TurnJumpSheet: View {
    let outline: [TurnOutline]
    let jump: (TurnOutline) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(outline) { entry in
                Button { jump(entry) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("第 \(entry.turn) 轮").font(.caption).foregroundStyle(Palette.secondary)
                        if !entry.prompt.isEmpty { Text(entry.prompt).font(.callout).foregroundStyle(Palette.ink).lineLimit(2) }
                        if !entry.response.isEmpty { Text(entry.response).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(3) }
                    }
                }
                .groupedRow()
            }
            .groupedList()
            .navigationTitle("跳转到轮次")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
        }
    }
}

/// Older messages arrive by themselves when the top of the timeline comes into view (C-11),
/// a spinner meanwhile. Not `onAppear`: this stack is not lazy, so that fires on the first
/// layout wherever the reader is, and every page loaded would load the next.
private struct LoadOlderTrigger: View {
    let model: SessionModel
    @Environment(\.timelineScroll) private var scroll
    @State private var inView = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: 36)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { inView = $0 > scroll.top }
            // Again for each page: one that leaves the top in view needs the next.
            .task(id: "\(inView)-\(model.items.first?.id ?? "")") {
                guard inView else { return }
                // The first layout has this in view until the bottom anchor takes hold.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let anchor = model.items.first?.id
                // Its own task: scrolling on must not cancel the request halfway.
                Task {
                    await model.loadOlder()
                    // Keep the row the reader was on in place instead of jumping to the new top.
                    if let anchor { scroll.keep(anchor) }
                }
            }
            .accessibilityLabel("正在加载更早的消息")
    }
}

/// C-46. The official hint tells the user to send 「继续」; on a phone that is one button.
private struct MaxTokensNotice: View {
    let model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(state: .waiting)
                Text("已达到输出 token 上限").font(.subheadline.weight(.medium))
            }
            Text("回答被截断，已有输出保留在对话中。发送“继续”可让模型接着输出。")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
            if !model.running {
                Button("继续") { Haptics.tap(); Task { await model.send(text: String(localized: "继续")) } }
                    .buttonStyle(.capsule(.outline, height: 44, fill: false))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UserBubble: View {
    let text: String
    let attachments: [Attachment]
    let model: SessionModel
    /// The chat app the message came in over (a Bot reached from one), by name.
    var via: String?
    /// Just sent: it rises from the composer into place.
    var arrives = false
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    /// A long message (询问 AI writes one with an install log) folds to its first lines until asked for.
    @State private var open = false
    @State private var fullHeight: CGFloat = 0
    @State private var foldedHeight: CGFloat = 0
    @Environment(\.conversationActions) private var actions

    private static let foldedLines = 8

    var body: some View {
        let masked = SecretMask.masked(SessionMention.plain(text))
        let more = fullHeight > foldedHeight + 1
        VStack(alignment: .trailing, spacing: 6) {
            ImageGroup(attachments: attachments.filter(\.isImage), alignment: .trailing)
            ForEach(Array(attachments.filter { !$0.isImage }.enumerated()), id: \.offset) { _, attachment in
                FileCard(name: attachment.name ?? String(localized: "附件"), bytes: attachment.bytes)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
            if !text.isEmpty {
                Group {
                    if let masked, !revealed {
                        Text(masked).monospaced()
                    } else {
                        Text(text)
                    }
                }
                .lineLimit(open ? nil : Self.foldedLines)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !open { foldedHeight = $0 } }
                .background(alignment: .topLeading) {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
                .font(.callout)
                .lineSpacing(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .userBubble()
                .contextMenu {
                    Button { copyToPasteboard(text) } label: { Label("复制", systemImage: "doc.on.doc") }
                    // Masked text stays masked until the reader asks: this would show it whole.
                    if masked == nil || revealed {
                        Button { actions.present(.text(text)) } label: { Label("选择文本", systemImage: "selection.pin.in.out") }
                    }
                }
                if open || more {
                    Button { withAnimation(.snappy) { open.toggle() } } label: {
                        Text(open ? "收起" : "全文").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink).padding(.trailing, 6)
                    }
                    .buttonStyle(.plain)
                }
                if masked != nil {
                    Button { revealed.toggle() } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye").font(.caption).foregroundStyle(Palette.secondary).hitTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealed ? "隐藏密钥" : "显示密钥")
                }
            }
            if let via {
                Label("来自\(via)", systemImage: "arrow.down.left.circle").font(.caption2).foregroundStyle(Palette.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 60)
        .opacity(arrives && !landed ? 0 : 1)
        .scaleEffect(arrives && !landed && !reduceMotion ? 0.9 : 1, anchor: .bottomTrailing)
        .offset(y: arrives && !landed && !reduceMotion ? 36 : 0)
        .task {
            guard arrives, !landed else { return }
            // After the pass that laid the new row out: started inside it, most of the rise is over before a frame is drawn.
            await Task.yield()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) { landed = true }
        }
    }
}

/// One assistant turn. Its work (reasoning and tool calls) sits under one grey line
/// above the answer: what it is doing while it runs (open), and once done its title
/// with 「已完成，用时…」 (folded, unless it failed, was stopped or was steered: C-32).
/// A finished turn adds its plan and file cards; its actions are a long press away (`TurnMenu`).
struct AssistantTurnView: View {
    let blocks: [AssistantBlock]
    /// nil for the streamed attempt, which has no turn yet.
    let turn: Int?
    let inProgress: Bool
    /// The trailing blocks still being streamed.
    var liveCount = 0
    let startedAt: Date?
    let endedAt: Date?
    var regeneratePrompt: String?
    var info: TurnInfo?
    /// nil until the reader taps the line; then their choice holds for this turn.
    @State private var choice: Bool?
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationActions) private var actions
    /// A Bot's chat: its reasoning shows only when asked for, and what it did beyond its words is drawn.
    @Environment(\.botTimeline) private var bot
    /// A Bot's own chat: the Bot's mark at the tail is the one loading indicator.
    @Environment(\.botComposer) private var botChat

    private var stayOpen: Bool {
        inProgress || info?.steered == true || ["aborted", "interrupted", "error"].contains(info?.closedKind ?? "")
    }

    var body: some View {
        let finalStart = finalAnswerStart
        let finished = !inProgress && endedAt != nil
        let showWork = choice ?? stayOpen
        let ownChat = if case .bot? = botChat { true } else { false }
        // A Bot's own chat at work shows nothing of the turn: the Bot's line below says what it is
        // doing, and its reply arrives whole when the turn ends. Words it ends on a card with show
        // at once, since the card waits on the user.
        let quiet = inProgress && ownChat
        // A Bot's reply held back while it was written comes in as a whole: it fades and rises into
        // place. Decided from when the turn ended, so the first pass that shows it already knows.
        let arrives = ownChat && finished && endedAt.map { -$0.timeIntervalSinceNow < 3 } == true
        let tailShown = !quiet || blocks.dropFirst(finalStart).contains { block in
            if case .tool(let call) = block { BotTurnEvents.cards.contains(call.displayName) } else { false }
        }
        VStack(alignment: .leading, spacing: 8) {
            // While working the step line always shows (the one loading indicator of the turn);
            // a streamed answer with no work before it needs none.
            if !quiet, finalStart > 0 || (inProgress && !ownChat && (blocks.isEmpty || liveCount == 0)) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { choice = !showWork }
                } label: {
                    HStack(spacing: 6) {
                        if inProgress && !ownChat { ProgressView().controlSize(.mini) }
                        Text(summaryLine).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.faint)
                            .rotationEffect(.degrees(showWork ? 90 : 0))
                    }
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(showWork ? "收起步骤" : "展开步骤")
                if showWork, finalStart > 0 {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(blocks.prefix(finalStart).enumerated()), id: \.element.id) { index, block in
                            if bot?.hides(block) != true { BlockView(block: block, live: isLive(index)).equatable() }
                        }
                        if let bot, bot.showsThinking, let turn, finished { BotThinkingTime(turn: turn) }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Palette.stroke).frame(width: 2) }
                }
            }
            // In a Bot's chat: what it did while working, above its words; a card it ended on, below them.
            if bot != nil && !quiet { BotTurnEvents(blocks: Array(blocks.prefix(finalStart))) }
            if tailShown {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated().dropFirst(finalStart)), id: \.element.id) { index, block in
                        if case .tool = block {} else {
                            BlockView(block: block, live: isLive(index), closing: finished).equatable()
                                .environment(\.fileMentions, finished ? mentions : [:])
                        }
                    }
                    if bot != nil { BotTurnEvents(blocks: Array(blocks.dropFirst(finalStart))) }
                }
                .opacity(arrives && !landed ? 0 : 1)
                .blur(radius: arrives && !landed && !reduceMotion ? 6 : 0)
                .offset(y: arrives && !landed && !reduceMotion ? 14 : 0)
                .task(id: arrives) {
                    guard arrives, !landed else { return }
                    // As the user's own bubble does: after the pass that laid the row out.
                    await Task.yield()
                    withAnimation(.smooth(duration: 0.45)) { landed = true }
                }
            }
            if finished {
                ForEach(plans, id: \.plan) { plan in PlanCard(title: plan.title, plan: plan.plan) }
                if let files = info?.deliverables, !files.isEmpty { DeliverableCards(files: files) }
                let changes = FileChange.collect(blocks)
                if !changes.isEmpty { ChangeCapsule(changes: changes, open: actions.openChanges) }
                if let bot, let turn { BotReactionChip(key: BotReactions.key(session: bot.sessionId, turn: turn)) }
            }
        }
        .modifier(TurnMenu(enabled: finished, turn: turn, info: info, fallbackText: answerText, regeneratePrompt: regeneratePrompt))
    }

    private var mentions: [String: String] {
        FileMentions.make((info?.producedPaths ?? []) + (info?.deliverables.map(\.path) ?? []))
    }

    private var answerText: String {
        blocks.compactMap { if case .text(_, let text) = $0 { return text }; return nil }.joined()
    }

    private var plans: [(title: String, plan: String)] {
        blocks.compactMap { block in
            guard case .tool(let call) = block, call.displayName == "exit_plan_mode",
                  let plan = call.arguments["plan"].string, let title = PlanCard.title(of: plan) else { return nil }
            return (title, plan)
        }
    }

    /// Index of the trailing run of text blocks (the answer after the last tool call).
    private var finalAnswerStart: Int {
        var index = blocks.count
        // A Bot often says something and then ends its turn on a card (a question, a view, a
        // request): those words are its reply, not narration of work, so the card counts as the tail.
        if bot != nil {
            while index > 0 {
                if case .text = blocks[index - 1] { index -= 1; continue }
                if case .tool(let call) = blocks[index - 1], BotTurnEvents.cards.contains(call.displayName) { index -= 1; continue }
                break
            }
            // Only cards and no words: nothing to lift out of the steps.
            if !blocks[index...].contains(where: { if case .text = $0 { true } else { false } }) { index = blocks.count }
            return index
        }
        while index > 0, case .text = blocks[index - 1] { index -= 1 }
        return index
    }

    private func isLive(_ index: Int) -> Bool { inProgress && index >= blocks.count - liveCount }

    private var calls: [ToolCall] {
        blocks.compactMap { if case .tool(let call) = $0 { return call }; return nil }
    }

    private var summaryLine: String {
        if inProgress {
            // As the web: the running tool, else the reasoning streaming, else the model is on its next step.
            if case .tool(let call)? = blocks.prefix(finalAnswerStart).last, !call.finished {
                let kind = StepKind(tool: call.name)
                let streaming = isLive(finalAnswerStart - 1)
                return [streaming ? kind.preparing : kind.running, call.summary].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            if case .reasoning(_, let text)? = blocks.last, liveCount > 0 {
                let summary = ReasoningSummary.make(text, live: true)
                if !summary.isEmpty { return summary }
            }
            return StepKind.thinking.running
        }
        return [StepKind.title(calls: calls), closedLabel].compactMap { $0 }.joined(separator: " · ")
    }

    private var closedLabel: String? {
        switch info?.closedKind {
        case "aborted", "interrupted": return String(localized: "已停止")
        case "error": return String(localized: "处理失败")
        default:
            guard let endedAt, let start = info?.startedAt ?? startedAt else { return endedAt == nil ? nil : String(localized: "已完成") }
            let seconds = Int(endedAt.timeIntervalSince(start).rounded())
            return seconds >= 1 ? String(localized: "已完成，用时 ") + TimelineFormat.duration(seconds) : String(localized: "已完成")
        }
    }
}

/// 「深度求索中，用时 12秒 ···」 at the tail of a running turn (C-16).
private struct RunningIndicator: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if let since {
                    Text("深度求索中，用时 \(TimelineFormat.duration(max(1, Int(context.date.timeIntervalSince(since))))) ···")
                } else {
                    Text("深度求索中")
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 「改动了 N 个文件 +a −b」: opens the workbench on 改动. A line like the work above it, not a button to reckon with.
private struct ChangeCapsule: View {
    let changes: [FileChange]
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            WorkRowLabel(
                systemImage: "doc",
                text: String(localized: "改动了 \(changes.count) 个文件") + " +\(changes.reduce(0) { $0 + $1.added }) −\(changes.reduce(0) { $0 + $1.removed })"
            )
        }
        .buttonStyle(.plain)
    }
}

private struct BlockView: View, Equatable {
    let block: AssistantBlock
    let live: Bool
    /// In the closing message of a finished turn, which links file names (C-24).
    var closing = false

    var body: some View {
        switch block {
        case .reasoning(let id, let text):
            ReasoningView(id: id, text: text, live: live)
        case .text(_, let text):
            MarkdownView(text: text, cached: !live, linksFiles: closing, selectable: false)
        case .tool(let call):
            ToolCallView(call: call, live: live)
        case .image(_, let attachment):
            ImageGroup(attachments: [attachment])
        }
    }
}

/// The reasoning's first line as a row, the same as a tool call's (C-25); the whole of it in a sheet.
private struct ReasoningView: View {
    let id: String
    let text: String
    let live: Bool
    @Environment(\.conversationActions) private var actions

    var body: some View {
        let summary = ReasoningSummary.make(text, live: live)
        Button {
            actions.present(.reasoning(id: id, text: text))
        } label: {
            WorkRowLabel(systemImage: "lightbulb", text: summary.isEmpty ? String(localized: "思考") : summary)
        }
        .buttonStyle(.plain)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            Button { copyToPasteboard(text) } label: { Label("复制", systemImage: "doc.on.doc") }
        }
        .accessibilityLabel(Text("思考：\(summary)"))
    }
}

/// A reasoning block in full; it keeps growing while the model thinks.
struct ReasoningSheet: View {
    let id: String
    let text: String
    var model: SessionModel?
    /// The text as it stands now, where no session model holds it (a remote session).
    var current: ((String) -> String?)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let text = model?.reasoningText(id) ?? current?(id) ?? text
        NavigationStack {
            ScrollView {
                MarkdownView(text: text, cached: false).padding(16).modifier(LinkOpening())
            }
            .background(Palette.background)
            .navigationTitle("思考")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { copyToPasteboard(text) } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("复制")
                }
            }
            .closeButton(dismiss)
        }
        .detailSheet()
    }
}

/// 「允许运行这条命令？」: the command in full above the two answers, which stay under the
/// thumb. Pulling it down keeps it waiting behind the 「等你允许」 line; the conversation stays
/// usable behind it, to check what led here before answering.
struct ApprovalSheet: View {
    let approval: PendingApproval
    let call: ToolCall?
    /// Where this one stands among those waiting; nil when it is alone.
    var position: (current: Int, total: Int)?
    let answer: (Bool) -> Void

    var body: some View {
        PinnedActionsSheet {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if let position {
                        Text(verbatim: "\(position.current)/\(position.total)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Palette.secondary)
                            .accessibilityLabel(Text("第 \(position.current) 个，共 \(position.total) 个"))
                    }
                }
                ApprovalReasonText(text: ApprovalReasonText.plain(approval.reason) ?? String(localized: "\(ToolStyle.name(of: tool)) 需要你确认后才会执行。"))
                if let detail, !detail.isEmpty { CommandBlock(text: detail) }
            }
            .padding(EdgeInsets(top: 28, leading: 22, bottom: 8, trailing: 22))
        } actions: {
            HStack(spacing: 10) {
                Button("拒绝") { Haptics.tap(); answer(false) }.buttonStyle(.capsule(.secondary))
                Button("允许") { Haptics.success(); answer(true) }.buttonStyle(.capsule())
            }
            .padding(EdgeInsets(top: 10, leading: 22, bottom: 22, trailing: 22))
        }
    }

    private var tool: ToolCall { call ?? ToolCall(id: "", name: approval.toolName, arguments: .null, rawArguments: "") }

    private var title: String {
        switch tool.displayName {
        case "bash", "pwsh", "terminal": String(localized: "允许运行这条命令？")
        case "edit", "str_replace", "str_replace_editor", "multi_edit", "write", "write_file", "create", "apply_patch": String(localized: "允许修改这个文件？")
        case "web_fetch", "fetch": String(localized: "允许访问这个网页？")
        default: String(localized: "允许使用「\(ToolStyle.name(of: tool))」？")
        }
    }

    private var detail: String? {
        guard let call else { return nil }
        return call.arguments["command"].string ?? call.summary
    }
}

/// The reason an approval gives, two lines of it until tapped: it is the model's own prose.
private struct ApprovalReasonText: View {
    let text: String
    @State private var open = false
    @State private var fullHeight: CGFloat = 0
    @State private var clippedHeight: CGFloat = 0

    /// The mode names the engine and the model write, in the words the permission menu uses.
    static func plain(_ reason: String?) -> String? {
        guard var text = reason, !text.isEmpty else { return nil }
        let names = [
            "danger-full-access": String(localized: "完全权限"),
            "workspace-write": String(localized: "工作区内修改"),
            "read-only": String(localized: "仅可查看"),
        ]
        for (mode, name) in names {
            let quoted = String(localized: "「\(name)」")
            // 「使用 danger-full-access 权限」: the name already says 权限.
            text = text.replacingOccurrences(of: "\(mode) 权限", with: quoted)
            text = text.replacingOccurrences(of: "(?<![\\w-])\(mode)(?![\\w-])", with: quoted, options: .regularExpression)
        }
        return text
    }

    var body: some View {
        let more = fullHeight > clippedHeight + 1
        Button {
            guard open || more else { return }
            withAnimation(.snappy) { open.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .lineLimit(open ? nil : 2)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !open { clippedHeight = $0 } }
                    .background(alignment: .topLeading) {
                        Text(text)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    }
                if open || more {
                    Text(open ? "收起" : "全文").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink)
                }
            }
            .font(.subheadline)
            .foregroundStyle(Palette.secondary)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What is being approved, every character of it: lines wrap, and a long one scrolls in its
/// own block with a note that it does, so nothing is agreed to unseen.
private struct CommandBlock: View {
    let text: String
    @State private var height: CGFloat = 52
    private let limit: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(text)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .frame(height: min(height, limit))
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicatorsFlash(onAppear: true)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if height > limit {
                Text("内容较长，滑动查看全部").font(.caption).foregroundStyle(Palette.secondary)
            }
        }
    }
}

/// What a conversation in the split view's detail can do with the sidebar. Equal while the same
/// actions are there: a closure is new on every pass of the view that sets it, and an environment
/// value that changes each time redraws everything under it.
struct SplitSidebar: Equatable {
    /// A narrow window gives up its sidebar for the workbench.
    var makeRoom: () -> Void = {}
    /// Shows or hides the sidebar, where the bar needs a button for it (nil where the system's is there).
    var toggle: (() -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool { (lhs.toggle == nil) == (rhs.toggle == nil) }
}

/// The workbench beside the conversation. From iPadOS 26 on, an inspector. Before that an inspector
/// on an upright iPad is laid over the conversation, dimmed under it, so there it is a column of its own.
private struct WorkbenchBeside<Page: View>: ViewModifier {
    @Binding var shown: Bool
    let regular: Bool
    @ViewBuilder let page: () -> Page

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.inspector(isPresented: $shown) {
                // Only where it is shown: on a phone this content stays built while closed, and its
                // toolbar lands in the conversation's bar.
                if regular { page().inspectorColumnWidth(min: 320, ideal: 420, max: 640) }
            }
        } else {
            HStack(spacing: 0) {
                content
                if shown && regular {
                    HStack(spacing: 0) {
                        Divider()
                        page().frame(width: 420)
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.3), value: shown && regular)
        }
    }
}
