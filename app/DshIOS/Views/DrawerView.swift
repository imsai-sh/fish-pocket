import SwiftUI

/// The left drawer (the iPad sidebar) is for finding a session. One list: the feature rows
/// (插件 … 远程控制), the sessions under a header that carries the view menu (by time, by
/// workspace, by device), and 「已归档」 at the end. The app's name and the search button float
/// over its top, settings and the new conversation button over its bottom; search itself is a
/// page of its own over everything (docs/design/README.md 4.2).
struct DrawerView: View {
    /// `device` joins once the user has signed in to remote control: this phone, then each computer.
    enum GroupBy: String { case time, workspace, device }

    /// Where a session sits in the time view.
    enum Period: CaseIterable {
        case pinned, today, week, earlier

        var title: String {
            switch self {
            case .pinned: String(localized: "drawer.section.pinned", defaultValue: "置顶", comment: "Section header; the swipe action 置顶 is a verb")
            case .today: String(localized: "今天")
            case .week: String(localized: "本周")
            case .earlier: String(localized: "更早")
            }
        }
    }

    private enum Route: Hashable { case archived }

    @Environment(AppModel.self) private var app
    @EnvironmentObject private var engine: NodeEngine
    let selection: String?
    /// Where a new conversation from the top button goes: the current session's workspace.
    let workspace: Workspace?
    /// Tells the root view where session rows are: a swipe there is the row's.
    let rowFrames: DrawerRowFrames
    /// The plugin store is what the window shows beside the sidebar.
    var pluginsSelected = false
    let select: (String) -> Void
    let newConversation: (Workspace) -> Void
    let openSettings: () -> Void
    let openSchedules: () -> Void
    let openCordis: () -> Void
    let openSignIn: () -> Void
    /// Bumped to put the cursor in the search field (⌘K).
    var searchRequest = 0
    /// Open a session in a window of its own, where the system has windows.
    var openInWindow: ((String) -> Void)?

    @AppStorage("dsh.drawer.groupBy") private var groupBy = GroupBy.workspace
    /// Groups the user opened or closed, as JSON `{workspaceId: Bool}`.
    @AppStorage("dsh.drawer.expansion") private var expansionJSON = "{}"
    /// How many sessions each group shows beyond the base five.
    @State private var watermark: [String: Int] = [:]
    @State private var search = ""
    /// The search page is up; `searchShown` fades it, `searchActive` is the system field's focus.
    @State private var searchOpen = false
    @State private var searchShown = false
    @State private var searchActive = false
    @State private var remoteHits: [String: String] = [:]
    @State private var remoteMore = false
    @State private var searching = false
    @State private var removingWorkspace: Workspace?
    @State private var showNewWorkspace = false

    private static let ungrouped = ""
    private static let baseRows = 5
    private static let autoMaxRows = 50
    private static let searchLimit = 20

    var body: some View {
        NavigationStack {
            List {
                // The Bot card keeps its own margins: wider than the rows under it.
                BotDrawerEntry()
                    .padding(.top, 4)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                pluginsRow
                connectorsRow
                capabilitiesRow
                webRow
                remoteControlRow
                sessionsHeader
                if app.remote.expired { remoteExpiredRow }
                if grouping == .time { timeList } else { groupList }
                archivedEntry
            }
            .sessionList()
            .refreshable {
                await app.refreshSessions()
                await app.remote.refresh()
            }
            // Both bars float: the list scrolls under them, up to the screen's edges.
            .floatingBars(top: topBar, bottom: bottomBar)
            .background(Palette.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { _ in archivedPage }
        }
        .task(id: search) { await searchRemote() }
        .onChange(of: searchRequest) { openSearch() }
        .fullScreenCover(isPresented: $searchOpen) { searchPage }
        .onChange(of: groupBy) { Haptics.select() }
        .onChange(of: selection) { revealSelection() }
        .onChange(of: selectionRowGroupId) { revealSelection() }
        .confirmationDialog("删除「\(removingWorkspace?.displayTitle ?? "")」？", isPresented: Binding(get: { removingWorkspace != nil }, set: { if !$0 { removingWorkspace = nil } }), titleVisibility: .visible) {
            Button("删除工作区", role: .destructive) {
                if let workspace = removingWorkspace {
                    Task { await app.perform { try await app.client.call("workspace/delete", ["request": ["workspaceId": .string(workspace.id)]]) } }
                }
            }
        } message: {
            Text("文件夹和会话都会保留，会话移到「未分组」。")
        }
        .sheet(isPresented: $showNewWorkspace) { NewWorkspaceView() }
    }

    // MARK: Header and footer

    /// The app's name, and search one tap away. No fill of its own: the list shows through.
    private var topBar: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Fish Pocket").font(.title2.weight(.bold)).foregroundStyle(Palette.ink)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button { Haptics.tap(); openSearch() } label: {
                Image(systemName: "magnifyingglass").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
                    .floatingGlass(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索会话")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        // A bar, as the system's are: its controls have fixed sizes and do not grow without limit.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: Search

    /// Search is a page of its own over everything, not a field in the drawer: the system's
    /// search field (in glass at the bottom from iOS 26, in the bar before) and the matches.
    /// It fades in over the drawer rather than sliding up as a cover does.
    private var searchPage: some View {
        NavigationStack {
            List {
                if !search.trimmingCharacters(in: .whitespaces).isEmpty { searchResults }
            }
            .sessionList()
            .overlay(alignment: .top) {
                if search.trimmingCharacters(in: .whitespaces).isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(Palette.ink)
                        Text("搜索会话标题和消息内容").font(.subheadline).foregroundStyle(Palette.secondary)
                    }
                    .padding(.top, 96)
                    .accessibilityElement(children: .combine)
                }
            }
            .background(Palette.background)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, isPresented: $searchActive, prompt: "搜索会话")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .searchFieldAtBottom()
        }
        .tint(Palette.ink)
        .opacity(searchShown ? 1 : 0)
        .presentationBackground(.clear)
        .onAppear { withAnimation(.easeOut(duration: 0.2)) { searchShown = true } }
        // The field's own ✕ (取消 before iOS 26) is the way out.
        .onChange(of: searchActive) { if !searchActive { closeSearch() } }
    }

    private func openSearch() {
        guard !searchOpen else { return }
        searchActive = true
        withoutAnimation { searchOpen = true }
    }

    private func closeSearch() {
        guard searchOpen, searchShown else { return }
        searchActive = false
        withAnimation(.easeIn(duration: 0.15)) { searchShown = false } completion: {
            search = ""
            withoutAnimation { searchOpen = false }
        }
    }

    /// Opens a session from any list here. From the search page, the page goes at once:
    /// the drawer under it is closing too.
    private func open(_ id: String) {
        if searchOpen {
            search = ""
            searchShown = false
            searchActive = false
            withoutAnimation { searchOpen = false }
        }
        select(id)
    }

    /// The cover's own slide is not wanted: the page fades.
    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    // MARK: Footer

    /// Over the list's bottom: settings (the account's picture once signed in) and the new
    /// conversation button, the one filled control here. The engine shows only when it is not running.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            settingsButton
            if let engineStatus {
                Text(engineStatus).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            newConversationButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// With computers connected it first asks where: this phone, or one of them.
    @ViewBuilder
    private var newConversationButton: some View {
        if remote.signedIn, !remote.devices.isEmpty {
            Menu {
                Button { startLocalConversation() } label: { Label("在本机", systemImage: "iphone") }
                    .disabled(app.workspaces.isEmpty)
                Section("在电脑上") {
                    ForEach(remote.devices) { device in
                        Button { app.remoteSessionRequest = RemoteSessionTarget(deviceId: device.id) } label: {
                            Label(device.online ? device.name : String(localized: "\(device.name)（离线）"), systemImage: device.symbol)
                        }
                        .disabled(!device.online)
                    }
                }
            } label: {
                newConversationLabel
            }
            .accessibilityLabel("新会话，选择在本机还是电脑上")
        } else {
            Button(action: startLocalConversation) { newConversationLabel }
                .buttonStyle(.plain)
                .disabled(app.workspaces.isEmpty)
                .opacity(app.workspaces.isEmpty ? 0.4 : 1)
        }
    }

    private var newConversationLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
            Text("新会话").lineLimit(1).fixedSize()
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(Palette.onInk)
        .padding(.horizontal, 18)
        .frame(minHeight: 46)
        .background(Palette.ink, in: Capsule())
        .contentShape(Capsule())
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }

    private func startLocalConversation() {
        if let target = workspace ?? app.workspaces.first { newConversation(target) }
    }

    /// Plugins are found here rather than three levels down in settings.
    private var pluginsRow: some View {
        Button { Haptics.tap(); app.pluginStoreRequest = UUID() } label: {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension").font(.callout).foregroundStyle(Palette.ink).frame(width: 22)
                Text("插件").font(.subheadline.weight(pluginsSelected ? .medium : .regular)).foregroundStyle(Palette.ink)
                Spacer()
                if !pluginsSelected { Text("发现").font(.footnote).foregroundStyle(Palette.secondary) }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(pluginsSelected ? Palette.bubble : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
        .plainRow()
    }

    /// The services an agent can reach over MCP (GitHub, Notion…). They come with the Bot
    /// plugin but every conversation gets their tools, so the way in is here, not only in the
    /// Bot team's settings; the row shows once that plugin answers.
    @ViewBuilder
    private var connectorsRow: some View {
        let team = app.botTeam
        if team.status == .ready {
            let connected = team.connectors.filter { $0["state"].string == "ready" }.count
            Button { Haptics.tap(); app.connectorsRequest = UUID() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.callout).foregroundStyle(Palette.ink).frame(width: 22)
                    Text("连接器").font(.subheadline).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(connected > 0 ? String(localized: "\(connected) 个已连接") : String(localized: "连接服务")).font(.footnote).foregroundStyle(Palette.secondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 2)
            .plainRow()
        }
    }

    /// What the agent may reach on this phone, and the switch for each one.
    ///
    /// A row of its own rather than a line in settings: nothing asks for these
    /// permissions on its own any more (docs/native-services.md §5.5), so if this
    /// is hard to find, the capabilities are simply never turned on.
    private var capabilitiesRow: some View {
        Button { Haptics.tap(); app.nativeCapabilitiesRequest = UUID() } label: {
            HStack(spacing: 12) {
                Image(systemName: "iphone").font(.callout).foregroundStyle(Palette.ink).frame(width: 22)
                Text("本机能力").font(.subheadline).foregroundStyle(Palette.ink)
                Spacer()
                Text("授权").font(.footnote).foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
        .plainRow()
    }

    /// The web version: plugin interfaces are not shown natively, so it gets a row of its own.
    private var webRow: some View {
        Button { Haptics.tap(); app.webRequest = UUID() } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe").font(.callout).foregroundStyle(Palette.ink).frame(width: 22)
                Text("网页版").font(.subheadline).foregroundStyle(Palette.ink)
                Spacer()
                Text("插件界面").font(.footnote).foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
        .plainRow()
    }

    /// The computers of the user's Agents Anywhere account: signing in, then the machines themselves.
    /// A row here, not a line in settings: until it is found, nothing of it shows anywhere else.
    private var remoteControlRow: some View {
        Button { Haptics.tap(); app.remoteRequest = UUID() } label: {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.iphone").font(.callout).foregroundStyle(Palette.ink).frame(width: 22)
                Text("远程控制").font(.subheadline).foregroundStyle(Palette.ink)
                Spacer()
                Text(remoteControlNote).font(.footnote).foregroundStyle(remote.expired ? Palette.waiting : Palette.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
        .plainRow()
    }

    private var remoteControlNote: String {
        if remote.expired { return String(localized: "重新登录") }
        // Signed in with no computer on the account yet (or the last one removed): the same invitation.
        guard remote.signedIn, !remote.devices.isEmpty else { return String(localized: "连接电脑") }
        let online = remote.devices.filter(\.online).count
        return online > 0 ? String(localized: "\(online) 台在线") : String(localized: "电脑离线")
    }

    /// What the list under it is, and how it is grouped: the view menu sits with the sessions it arranges.
    private var sessionsHeader: some View {
        HStack(spacing: 8) {
            Text("会话").font(.footnote).foregroundStyle(Palette.secondary).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            viewMenu
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.top, 6)
        .plainRow()
    }

    private var viewMenu: some View {
        Menu {
            Picker("分组方式", selection: Binding(get: { grouping }, set: { groupBy = $0 })) {
                Label("按时间", systemImage: "clock").tag(GroupBy.time)
                Label(app.remote.signedIn ? "按项目" : "按工作区", systemImage: "folder").tag(GroupBy.workspace)
                if app.remote.signedIn { Label("按设备", systemImage: "laptopcomputer.and.iphone").tag(GroupBy.device) }
            }
            .pickerStyle(.inline)
            Button { showNewWorkspace = true } label: { Label("添加工作区", systemImage: "folder.badge.plus") }
            if app.remote.signedIn {
                Button { app.remoteSessionRequest = RemoteSessionTarget() } label: { Label("在电脑上新建会话", systemImage: "laptopcomputer") }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(groupingTitle)
            }
            .font(.footnote)
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 8)
            .hitTarget()
        }
        .accessibilityLabel("视图选项")
        .accessibilityValue(groupingTitle)
    }

    private var groupingTitle: String {
        switch grouping {
        case .time: String(localized: "按时间")
        case .workspace: app.remote.signedIn ? String(localized: "按项目") : String(localized: "按工作区")
        case .device: String(localized: "按设备")
        }
    }

    /// Settings on a tap. Holding it reaches what is not about finding a session:
    /// automations (also in settings), the Cordis panel, signing in.
    /// Signed in, it is Platform's picture, as the web sidebar's account button is.
    private var settingsButton: some View {
        Menu {
            Button(action: openSettings) { Label("设置", systemImage: "gearshape") }
            Button(action: openSchedules) {
                if let count = app.scheduleCount, count > 0 {
                    Label("自动化（\(count)）", systemImage: "clock")
                } else {
                    Label("自动化", systemImage: "clock")
                }
            }
            if !app.cordis.rows.isEmpty {
                Button(action: openCordis) {
                    if app.cordis.runningCount > 0 {
                        Label("Cordis 插件（\(app.cordis.runningCount) 运行中）", systemImage: "shippingbox")
                    } else {
                        Label("Cordis 插件", systemImage: "shippingbox")
                    }
                }
            }
            if !app.account.signedIn {
                Button(action: openSignIn) { Label("登录", systemImage: "person") }
            }
        } label: {
            Group {
                if app.account.signedIn {
                    AccountAvatar(url: app.account.profileValue?["avatarUrl"].string.flatMap(URL.init(string:)), size: 38)
                } else {
                    Image(systemName: "slider.horizontal.3").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                }
            }
            .frame(width: 46, height: 46)
            .floatingGlass(in: Circle())
            .contentShape(Circle())
        } primaryAction: {
            openSettings()
        }
        .accessibilityLabel(Text(accountTitle))
    }

    private var accountTitle: String {
        guard app.account.signedIn else { return String(localized: "设置") }
        let profile = app.account.profileValue
        return profile?["name"].string ?? profile?["contact"].string ?? String(localized: "已登录 DeepSeek")
    }

    private var engineStatus: String? {
        switch engine.phase {
        case .starting: String(localized: "引擎启动中")
        case .running: nil
        case .exited(let code): String(localized: "引擎已退出（\(code)）")
        }
    }

    // MARK: Groups

    /// A row of the list: a session of this phone's engine, or one on a computer.
    private enum Entry: Identifiable {
        case local(SessionSummary)
        case remote(RemoteSession)

        /// What the shell selects it by.
        var id: String {
            switch self {
            case .local(let session): session.id
            case .remote(let session): RemoteStore.selection(session.id)
            }
        }

        var date: Date {
            switch self {
            case .local(let session): session.updatedAt
            case .remote(let session): session.sortAt
            }
        }
    }

    private struct SessionGroup: Identifiable {
        let id: String
        var workspace: Workspace?
        /// A computer's own group, or the computer a project group is on.
        var device: RemoteDevice?
        var project: RemoteProject?
        /// The group of this phone, in the device view.
        var isPhone = false
        let title: String
        var symbol = "folder"
        let rows: [Entry]
    }

    private var remote: RemoteStore { app.remote }

    /// The stored choice, as far as it applies: 按设备 only means something while signed in.
    private var grouping: GroupBy { groupBy == .device && !remote.signedIn ? .workspace : groupBy }

    private var groups: [SessionGroup] { grouping == .device ? deviceGroups : placeGroups }

    /// One group per workspace in host order, then 「未分组」 when it has members; then each
    /// project on a computer, most recently used first. A project is a folder on one machine:
    /// two machines' projects of the same name stay two groups, each saying whose it is.
    private var placeGroups: [SessionGroup] {
        // The Bot team's workspace holds only its sessions, which the Bot card lists.
        let team = app.botTeam.teamWorkspaceId
        var result = app.workspaces.filter { $0.id != team }.map { SessionGroup(id: $0.id, workspace: $0, title: $0.displayTitle, rows: app.sessions(in: $0).map(Entry.local)) }
        let loose = app.sessions(in: nil)
        if !loose.isEmpty { result.append(SessionGroup(id: Self.ungrouped, title: String(localized: "未分组"), rows: loose.map(Entry.local))) }
        guard remote.signedIn else { return result }
        let known = Set(remote.projects.map(\.id))
        let byProject = Dictionary(grouping: remote.listed()) { session in session.projectId.flatMap { known.contains($0) ? $0 : nil } ?? "" }
        let projects = remote.projects.filter { byProject[$0.id] != nil }
            .sorted { (byProject[$0.id]?.first?.sortAt ?? .distantPast) > (byProject[$1.id]?.first?.sortAt ?? .distantPast) }
        for project in projects {
            result.append(SessionGroup(id: "remote-project:\(project.id)", device: remote.device(project.deviceId), project: project,
                                       title: project.name, rows: (byProject[project.id] ?? []).map(Entry.remote)))
        }
        for device in remote.devices {
            let rows = (byProject[""] ?? []).filter { $0.deviceId == device.id }
            if !rows.isEmpty {
                result.append(SessionGroup(id: "remote-loose:\(device.id)", device: device, title: String(localized: "未分组"), rows: rows.map(Entry.remote)))
            }
        }
        return result
    }

    /// This phone, then each computer of the account.
    private var deviceGroups: [SessionGroup] {
        let listed = remote.listed()
        return [SessionGroup(id: "device:", isPhone: true, title: String(localized: "本机"), symbol: "iphone", rows: timeRows.map(Entry.local))]
            + remote.devices.map { device in
                SessionGroup(id: "device:\(device.id)", device: device, title: device.name, symbol: device.symbol,
                             rows: listed.filter { $0.deviceId == device.id }.map(Entry.remote))
            }
    }

    @ViewBuilder
    private var groupList: some View {
        let groups = groups
        let expansion = expansion
        if groups.isEmpty { emptyRow("暂无会话") }
        ForEach(groups) { group in
            let open = expansion[group.id] ?? true
            groupHeader(group, open: open)
            if open {
                let shown = shownCount(group)
                ForEach(group.rows.prefix(shown)) { entry in entryRow(entry, in: group) }
                if group.rows.isEmpty {
                    Text("暂无会话")
                        .font(.footnote)
                        .foregroundStyle(Palette.faint)
                        .padding(.leading, 46)
                        .plainRow()
                } else if group.rows.count > Self.baseRows {
                    moreRow(group, shown: shown)
                }
            }
        }
    }

    /// A row inside a group. What the group already says is left out of the row: under a
    /// project nothing more, under a computer the project. Which agent runs a session is not
    /// said in the list (for most accounts it is the same one on every row): its page says it.
    @ViewBuilder
    private func entryRow(_ entry: Entry, in group: SessionGroup) -> some View {
        switch entry {
        case .local(let session):
            row(session, indent: true, subtitle: group.isPhone ? placeLine(of: session) : nil)
        case .remote(let session):
            remoteRow(session, indent: true, detail: group.project != nil || group.id.hasPrefix("remote-loose:")
                ? nil : remote.place(of: session))
        }
    }

    /// A tap folds the group; holding it starts a session there or manages the workspace.
    private func groupHeader(_ group: SessionGroup, open: Bool) -> some View {
        let holdsCurrent = selection.map { id in group.rows.contains { $0.id == id } } ?? false
        let offline = group.device?.online == false
        return Button {
            Haptics.select()
            withAnimation(.snappy(duration: 0.2)) { setExpanded(group, !open) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: group.symbol == "folder" ? (open ? "folder" : "folder.fill") : group.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(holdsCurrent ? Palette.ink : Palette.secondary)
                    .frame(width: 22)
                Text(group.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(offline ? Palette.secondary : Palette.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.faint)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer(minLength: 4)
                // A project says which computer it is on; a computer says when it is away.
                if let device = group.device {
                    Group {
                        if grouping == .device {
                            if offline { Text("离线").font(.caption).foregroundStyle(Palette.faint) }
                        } else {
                            MachineTag(name: device.name, symbol: device.symbol, dimmed: offline)
                        }
                    }
                    .padding(.trailing, 12)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(group.device.map { grouping == .device ? group.title : "\(group.title)，\($0.name)" } ?? group.title))
        .accessibilityValue(open ? Text("已展开") : Text("已收起"))
        .plainRow()
        .contextMenu {
            if let workspace = group.workspace {
                Button { setExpanded(group, true); newConversation(workspace) } label: { Label("新会话", systemImage: "square.and.pencil") }
                Button { app.renameRequest = RenameRequest(target: .workspace(workspace.id), initial: workspace.displayTitle) } label: { Label("重命名", systemImage: "pencil") }
                Button { copyToPasteboard(workspace.path); app.showToast(String(localized: "已复制"), tone: .success) } label: { Label("复制路径", systemImage: "doc.on.doc") }
                Button(role: .destructive) { removingWorkspace = workspace } label: { Label("删除工作区", systemImage: "trash") }
            } else if let device = group.device {
                Button { app.remoteSessionRequest = RemoteSessionTarget(deviceId: device.id, projectId: group.project?.id) } label: {
                    Label("新会话", systemImage: "square.and.pencil")
                }
                .disabled(!device.online)
                if let project = group.project {
                    Button { copyToPasteboard(project.path); app.showToast(String(localized: "已复制"), tone: .success) } label: { Label("复制路径", systemImage: "doc.on.doc") }
                }
                Button { app.remoteRequest = UUID() } label: { Label("管理电脑", systemImage: "laptopcomputer.and.iphone") }
            } else if group.isPhone, let target = workspace ?? app.workspaces.first {
                Button { newConversation(target) } label: { Label("新会话", systemImage: "square.and.pencil") }
            }
        }
    }

    /// 「展开其余 n 个会话」 five at a time (all when five or fewer remain), then 「收起」.
    private func moreRow(_ group: SessionGroup, shown: Int) -> some View {
        let hidden = group.rows.count - shown
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if hidden > 0 {
                    watermark[group.id] = hidden <= Self.baseRows ? group.rows.count : shown + Self.baseRows
                } else {
                    watermark[group.id] = nil
                }
            }
        } label: {
            Text(hidden > 0 ? "展开其余 \(hidden) 个会话" : "收起")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
                .padding(.leading, 46)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .plainRow()
    }

    /// The base five, raised (up to fifty) to keep the current, running and waiting sessions in view.
    private func shownCount(_ group: SessionGroup) -> Int {
        if let explicit = watermark[group.id] { return min(explicit, group.rows.count) }
        var count = min(Self.baseRows, group.rows.count)
        for (index, entry) in group.rows.enumerated() where index >= count && index < Self.autoMaxRows {
            let active: Bool = switch entry {
            case .local(let session): session.running || app.isWaiting(session.id)
            case .remote(let session): session.deviceOnline && (session.working || session.waiting)
            }
            if entry.id == selection || active { count = index + 1 }
        }
        return count
    }

    private var expansion: [String: Bool] {
        (try? JSONDecoder().decode([String: Bool].self, from: Data(expansionJSON.utf8))) ?? [:]
    }

    /// Groups start open (the web opens only the current one; on a phone every
    /// workspace should be a glance away, and each shows five rows); a group the
    /// user closed stays closed, the current session's included, until they open it
    /// or switch to a session inside it (`revealSelection`).
    private func isExpanded(_ group: SessionGroup) -> Bool {
        expansion[group.id] ?? true
    }

    /// The group whose rows show the current session. A new conversation is blank and
    /// in none until its first message, when it shows up here.
    private var selectionRowGroupId: String? {
        guard let selection else { return nil }
        return groups.first { $0.rows.contains { $0.id == selection } }?.id
    }

    /// Opens the group of a session just switched to (a new conversation's is its
    /// workspace's), or of one that just showed up in a group, so it shows where it lives.
    private func revealSelection() {
        guard grouping != .time, let selection else { return }
        // A blank conversation is in no row yet: its place is its workspace, or this phone in the device view.
        let home = grouping == .device ? (RemoteStore.sessionId(of: selection) == nil ? "device:" : nil) : app.workspace(of: selection)?.id
        guard let id = selectionRowGroupId ?? home, let group = groups.first(where: { $0.id == id }), !isExpanded(group) else { return }
        setExpanded(group, true)
    }

    private func setExpanded(_ group: SessionGroup, _ open: Bool) {
        var next = expansion
        next[group.id] = open
        if !open { watermark[group.id] = nil }
        if let data = try? JSONEncoder().encode(next), let text = String(data: data, encoding: .utf8) { expansionJSON = text }
    }

    // MARK: Time list, archive and search

    @ViewBuilder
    private var timeList: some View {
        let rows = timeEntries
        if rows.isEmpty { emptyRow("暂无会话") }
        let periods = Dictionary(grouping: rows, by: period(of:))
        ForEach(Period.allCases, id: \.self) { period in
            if let members = periods[period] {
                Text(period.title)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .padding(.leading, 14)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .plainRow()
                ForEach(members) { entry in flatRow(entry) }
            }
        }
    }

    /// A row outside any group says where it is: its place, and whose machine once there are several.
    @ViewBuilder
    private func flatRow(_ entry: Entry) -> some View {
        switch entry {
        case .local(let session):
            row(session, subtitle: placeLine(of: session), phoneTag: remote.signedIn)
        case .remote(let session):
            remoteRow(session, machine: true, detail: remote.place(of: session))
        }
    }

    /// Every session, this phone's and the computers': pinned, then most recent.
    private var timeEntries: [Entry] {
        let local = timeRows.map(Entry.local)
        guard remote.signedIn else { return local }
        return (local + remote.listed().map(Entry.remote)).sorted { lhs, rhs in
            let lp = isPinned(lhs), rp = isPinned(rhs)
            if lp != rp { return lp }
            return lhs.date > rhs.date
        }
    }

    private func isPinned(_ entry: Entry) -> Bool {
        switch entry {
        case .local(let session): app.isPinned(session.id)
        case .remote(let session): session.pinned
        }
    }

    private func period(of entry: Entry) -> Period {
        isPinned(entry) ? .pinned : Self.period(of: entry.date)
    }

    /// Every session of the list: pinned, then most recent.
    private var timeRows: [SessionSummary] {
        allSessions(includeArchived: false).sorted { lhs, rhs in
            let lp = app.pinned.firstIndex(of: lhs.id), rp = app.pinned.firstIndex(of: rhs.id)
            if (lp != nil) != (rp != nil) { return lp != nil }
            if let lp, let rp { return lp < rp }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func allSessions(includeArchived: Bool) -> [SessionSummary] {
        app.workspaces.flatMap { app.sessions(in: $0, includeArchived: includeArchived) }
            + app.sessions(in: nil, includeArchived: includeArchived)
    }

    static func period(of date: Date, now: Date = .now, calendar: Calendar = .current) -> Period {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) ? .week : .earlier
    }

    private var archivedRows: [SessionSummary] {
        allSessions(includeArchived: true).filter { app.isArchived($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The way to the archive, at the end of the list; nothing archived, nothing to see.
    @ViewBuilder
    private var archivedEntry: some View {
        let count = archivedRows.count + remote.listed(archived: true).count
        if count > 0 {
            NavigationLink(value: Route.archived) {
                HStack(spacing: 10) {
                    Image(systemName: "archivebox").font(.system(size: 15)).foregroundStyle(Palette.secondary).frame(width: 22)
                    Text("已归档").font(.subheadline).foregroundStyle(Palette.ink)
                    Spacer(minLength: 4)
                    Text("\(count)").font(.caption).foregroundStyle(Palette.faint)
                }
                .padding(.leading, 12)
            }
            .padding(.top, 8)
            .plainRow()
        }
    }

    private var archivedPage: some View {
        List {
            let rows = archivedRows
            let away = remote.listed(archived: true)
            if rows.isEmpty, away.isEmpty { emptyRow("暂无已归档会话") }
            ForEach(rows) { session in row(session, subtitle: placeLine(of: session)) }
            ForEach(away) { session in
                remoteRow(session, machine: true, detail: remote.place(of: session))
            }
        }
        .sessionList()
        .background(Palette.background)
        .navigationTitle("已归档")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
    }

    private func emptyRow(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Palette.secondary).padding(.horizontal, 12).plainRow()
    }

    /// The workspace under a row's title; with a single workspace it would say the same thing on every row.
    private func placeLine(of session: SessionSummary) -> String? {
        app.workspaces.count > 1 ? place(of: session) : nil
    }

    private func place(of session: SessionSummary) -> String {
        app.workspace(of: session.id)?.displayTitle ?? String(localized: "未分组")
    }

    /// Title or workspace-name matches first (newest first), then content hits from `session/search`,
    /// at most twenty. Archived sessions count, after the others: search is how one finds anything.
    private var searchMatches: [SessionSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let pool = allSessions(includeArchived: true)
        let local = pool
            .filter { app.title(of: $0.id).localizedCaseInsensitiveContains(query) || (app.workspace(of: $0.id)?.displayTitle.localizedCaseInsensitiveContains(query) ?? false) }
            .sorted { $0.updatedAt > $1.updatedAt }
        let localIds = Set(local.map(\.id))
        let remote = pool.filter { remoteHits[$0.id] != nil && !localIds.contains($0.id) }
        let matches = local + remote
        let ordered = matches.filter { !app.isArchived($0.id) } + matches.filter { app.isArchived($0.id) }
        return Array(ordered.prefix(Self.searchLimit))
    }

    /// Sessions on the computers whose title, project, machine or agent says the query; live ones first.
    private var remoteMatches: [RemoteSession] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard remote.signedIn, !query.isEmpty else { return [] }
        let hits = (remote.listed() + remote.listed(archived: true)).filter { session in
            [session.displayTitle, remote.place(of: session), remote.deviceName(of: session), session.agentTag]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return Array(hits.prefix(Self.searchLimit))
    }

    @ViewBuilder
    private var searchResults: some View {
        let away = remoteMatches
        let matches = searchMatches
        ForEach(matches) { session in
            row(session, subtitle: place(of: session) + (remoteHits[session.id].map { " · \($0)" } ?? ""))
        }
        ForEach(away) { session in
            remoteRow(session, machine: true, detail: remote.place(of: session))
        }
        if searching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在搜索会话历史…").font(.footnote).foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 12)
            .plainRow()
        } else if matches.isEmpty, away.isEmpty {
            emptyRow("无匹配会话")
        } else if remoteMore || matches.count >= Self.searchLimit {
            Text("仅显示前 \(Self.searchLimit) 条，请缩小范围").font(.footnote).foregroundStyle(Palette.faint).padding(.horizontal, 12).plainRow()
        }
    }

    /// Message-content search, 250 ms after typing stops; a newer query cancels this one.
    private func searchRemote() async {
        remoteHits = [:]
        remoteMore = false
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { searching = false; return }
        searching = true
        defer { if !Task.isCancelled { searching = false } }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled,
              let value = try? await app.client.call("session/search", ["request": ["query": .string(query)]]),
              !Task.isCancelled else { return }
        var hits: [String: String] = [:]
        for item in value["items"].array {
            if let id = item["sessionId"].string { hits[id] = item["snippet"].string ?? "" }
        }
        remoteHits = hits
        remoteMore = value["hasMore"].bool ?? false
    }

    // MARK: Rows

    /// The leading mark, by the web's status order: waiting, running, subagents
    /// running, an unread completion; an idle row with an active task shows a clock.
    @ViewBuilder
    private func leading(_ session: SessionSummary) -> some View {
        if app.isArchived(session.id) {
            Color.clear
        } else if app.isWaiting(session.id) {
            StatusDot(state: .waiting)
        } else if session.running {
            StatusDot(state: .running)
        } else if app.runningSubagentCount(of: session.id) > 0 {
            StatusDot(state: .running)
                .accessibilityLabel(Text("\(app.runningSubagentCount(of: session.id)) 个子智能体运行中"))
        } else if app.completionUnread.contains(session.id) {
            Circle().fill(Palette.ink).frame(width: 7, height: 7).accessibilityLabel(Text("已完成"))
        } else if !app.activeSchedules(of: session.id).isEmpty {
            Image(systemName: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary)
                .accessibilityLabel(Text("有定时任务"))
        } else {
            Color.clear
        }
    }

    /// A session: status mark, title (and the small line under it), then a waiting label or the relative time.
    /// An archived row does not open, as on the web: it offers to come back instead.
    private func row(_ session: SessionSummary, indent: Bool = false, subtitle: String? = nil, phoneTag: Bool = false) -> some View {
        let current = session.id == selection
        let archived = app.isArchived(session.id)
        let twoLine = subtitle != nil || phoneTag
        return Button {
            if archived { app.open(session: session.id) } else { open(session.id) }
        } label: {
            HStack(alignment: twoLine ? .top : .center, spacing: 8) {
                leading(session)
                .frame(width: 14, height: twoLine ? 20 : nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.title(of: session.id))
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if twoLine {
                        HStack(spacing: 6) {
                            if phoneTag { MachineTag(name: String(localized: "本机"), symbol: "iphone") }
                            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1) }
                        }
                    }
                }
                Spacer(minLength: 4)
                if app.isPinned(session.id) && !archived {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Palette.faint)
                }
                if archived {
                    Image(systemName: "archivebox").font(.caption).foregroundStyle(Palette.faint)
                } else if let pending = app.pendingLabel(of: session.id) {
                    Text(pending)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.waiting)
                } else {
                    Text(Self.relative(session.updatedAt)).font(.caption).foregroundStyle(Palette.faint)
                }
            }
            .padding(.leading, indent ? 22 : 4)
            .padding(.trailing, 12)
            .padding(.vertical, twoLine ? 8 : 3)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .opacity(archived ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
        .swipeActions(edge: .leading) {
            if !archived {
                Button {
                    Haptics.tap()
                    Task { await app.setPinned(session.id, !app.isPinned(session.id)) }
                } label: {
                    Label(app.isPinned(session.id) ? "取消置顶" : "置顶", systemImage: app.isPinned(session.id) ? "pin.slash" : "pin")
                }
                .tint(Palette.secondary)
            }
        }
        // No full swipe: a long leftward swipe is how the drawer closes, and must not archive.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Haptics.tap()
                Task { if archived { await app.unarchive(session.id) } else { await app.archive(session.id) } }
            } label: {
                Label(archived ? "取消归档" : "归档", systemImage: archived ? "tray.and.arrow.up" : "archivebox")
            }
            .tint(Palette.ink)
        }
        .contextMenu { menu(for: session) }
        .reportsFrame(session.id, to: rowFrames)
        // Outermost: below the frame report the list no longer sees them.
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(current ? Palette.bubble : .clear)
                .padding(.horizontal, 8)
        )
    }

    // MARK: Sessions on a computer

    /// The sign-in the server ended: one line at the top of the list, leading back to it.
    private var remoteExpiredRow: some View {
        Button { app.remoteRequest = UUID() } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.waiting)
                Text("远程控制的登录已失效").foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                Text("重新登录").foregroundStyle(Palette.secondary)
            }
            .font(.footnote)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .plainRow()
    }

    /// A session on a computer, in the shape of a local row: the same marks, the agent on the
    /// small line and, where the list does not already say it, its machine as a tag. One whose
    /// computer is away is dimmed: it opens, but only to its history.
    private func remoteRow(_ session: RemoteSession, indent: Bool = false, machine: Bool = false, detail: String?) -> some View {
        let id = RemoteStore.selection(session.id)
        let current = id == selection
        return Button {
            if session.archived {
                app.showToast(String(localized: "取消归档后才能查看"), tone: .warning, actions: [
                    Toast.Action(label: String(localized: "取消归档")) { remoteChange { await remote.setArchived(session.id, false) } },
                ])
            } else {
                open(id)
            }
        } label: {
            RemoteRowLabel(session: session, machine: machine ? remote.device(session.deviceId) : nil, detail: detail, indent: indent).equatable()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityValue(session.deviceOnline ? Text("") : Text("电脑离线"))
        .swipeActions(edge: .leading) {
            if !session.archived {
                Button {
                    Haptics.tap()
                    remoteChange { await remote.setPinned(session.id, !session.pinned) }
                } label: {
                    Label(session.pinned ? "取消置顶" : "置顶", systemImage: session.pinned ? "pin.slash" : "pin")
                }
                .tint(Palette.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Haptics.tap()
                remoteChange { await remote.setArchived(session.id, !session.archived) }
            } label: {
                Label(session.archived ? "取消归档" : "归档", systemImage: session.archived ? "tray.and.arrow.up" : "archivebox")
            }
            .tint(Palette.ink)
        }
        .contextMenu {
            if let openInWindow, !session.archived {
                Button { openInWindow(id) } label: { Label("在新窗口中打开", systemImage: "macwindow.badge.plus") }
            }
            if !session.archived {
                Button { remoteChange { await remote.setPinned(session.id, !session.pinned) } } label: {
                    Label(session.pinned ? "取消置顶" : "置顶会话", systemImage: session.pinned ? "pin.slash" : "pin")
                }
            }
            Button { app.renameRequest = RenameRequest(target: .session(id), initial: session.title ?? "") } label: { Label("重命名", systemImage: "pencil") }
            Button { remoteChange { await remote.setArchived(session.id, !session.archived) } } label: {
                Label(session.archived ? "取消归档" : "归档会话", systemImage: session.archived ? "tray.and.arrow.up" : "archivebox")
            }
            Button { copyToPasteboard(session.id); app.showToast(String(localized: "已复制"), tone: .success) } label: { Label("复制会话 ID", systemImage: "doc.on.doc") }
        }
        .reportsFrame(id, to: rowFrames)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(current ? Palette.bubble : .clear)
                .padding(.horizontal, 8)
        )
    }

    /// A change to a remote session; what the server refuses shows as a toast.
    private func remoteChange(_ work: @escaping () async -> String?) {
        Task {
            if let failure = await work() { app.showToast(failure, tone: .warning) }
        }
    }

    /// 刚刚 / N分钟 / N小时 / N天 / N个月 / N年 (docs/webui/shell.md A §4.3).
    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60), hours = minutes / 60, days = hours / 24
        if minutes < 1 { return String(localized: "刚刚") }
        if hours < 1 { return String(localized: "\(minutes)分钟") }
        if days < 1 { return String(localized: "\(hours)小时") }
        if days < 30 { return String(localized: "\(days)天") }
        if days < 365 { return String(localized: "\(days / 30)个月") }
        return String(localized: "\(days / 365)年")
    }

    /// The web row menu, in its order: pin, rename, fork, archive, copy the id.
    @ViewBuilder
    private func menu(for session: SessionSummary) -> some View {
        let archived = app.isArchived(session.id)
        if let openInWindow {
            Button { openInWindow(session.id) } label: { Label("在新窗口中打开", systemImage: "macwindow.badge.plus") }
        }
        if !archived {
            Button {
                Task { await app.setPinned(session.id, !app.isPinned(session.id)) }
            } label: { Label(app.isPinned(session.id) ? "取消置顶" : "置顶会话", systemImage: app.isPinned(session.id) ? "pin.slash" : "pin") }
        }
        Button { app.renameRequest = RenameRequest(target: .session(session.id), initial: app.durableTitle(of: session.id) ?? "") } label: { Label("重命名", systemImage: "pencil") }
        Button {
            Task { await app.fork(session: session.id, from: .menu) }
        } label: { Label("分叉会话", systemImage: "arrow.triangle.branch") }
        Button {
            Task { if archived { await app.unarchive(session.id) } else { await app.archive(session.id) } }
        } label: { Label(archived ? "取消归档" : "归档会话", systemImage: archived ? "tray.and.arrow.up" : "archivebox") }
        Button { app.copySessionId(session.id) } label: { Label("复制会话 ID", systemImage: "doc.on.doc") }
    }
}

/// Whose machine a session is on: a small tag, so it reads at a glance among rows of text.
struct MachineTag: View {
    let name: String
    let symbol: String
    var dimmed = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(name).font(.caption2.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(dimmed ? Palette.secondary : Palette.ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Palette.control, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// What a remote session's row shows. Compared by value: the list is told of every push from
/// the server, and a row whose session did not change is not drawn again.
private struct RemoteRowLabel: View, Equatable {
    let session: RemoteSession
    /// The machine to name on the row; nil where the group above already does.
    let machine: RemoteDevice?
    /// Where it is, as far as the group above does not say; nil for a row of one line.
    let detail: String?
    let indent: Bool

    var body: some View {
        let live = session.deviceOnline && !session.archived
        HStack(alignment: .top, spacing: 8) {
            Group {
                if !live {
                    Color.clear
                } else if session.waiting {
                    StatusDot(state: .waiting)
                } else if session.working {
                    StatusDot(state: .running)
                } else if session.hasUnread {
                    Circle().fill(Palette.ink).frame(width: 7, height: 7).accessibilityLabel(Text("已完成"))
                } else {
                    Color.clear
                }
            }
            .frame(width: 14, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle).font(.subheadline).foregroundStyle(Palette.ink).lineLimit(1)
                if machine != nil || detail != nil {
                    HStack(spacing: 6) {
                        if let machine { MachineTag(name: machine.name, symbol: machine.symbol, dimmed: !machine.online) }
                        if let detail { Text(detail).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1) }
                    }
                }
            }
            Spacer(minLength: 4)
            if session.pinned, !session.archived {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Palette.faint)
            }
            if session.archived {
                Image(systemName: "archivebox").font(.caption).foregroundStyle(Palette.faint)
            } else if live, session.waiting {
                Text("等你允许").font(.caption.weight(.medium)).foregroundStyle(Palette.waiting)
            } else {
                Text(DrawerView.relative(session.sortAt)).font(.caption).foregroundStyle(Palette.faint)
            }
        }
        .padding(.leading, indent ? 22 : 4)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .opacity(live ? 1 : 0.55)
        .contentShape(Rectangle())
    }
}

/// Where the drawer's session rows are in the window: a horizontal swipe
/// that starts on one belongs to the row, anywhere else in the drawer it closes it.
/// Only heights count, since a list cell spans the drawer past the row's insets.
/// A plain reference: rows report while scrolling, nothing redraws for it.
@MainActor
final class DrawerRowFrames {
    private var frames: [String: CGRect] = [:]
    /// Rows on screen. Frames stay when a row leaves: a row back from behind
    /// a pushed page has not moved, so it does not report again.
    private var shown: Set<String> = []

    func set(_ frame: CGRect, of id: String) { frames[id] = frame }
    func setShown(_ id: String, _ isShown: Bool) { if isShown { shown.insert(id) } else { shown.remove(id) } }
    func hasRow(atY y: CGFloat) -> Bool {
        shown.contains { id in frames[id].map { $0.minY...$0.maxY ~= y } ?? false }
    }
}

private extension View {
    /// The drawer's bars over its list. From iOS 26 they are the system's bars, and the list
    /// softens under them at both edges; before, a fade to the page colour does it.
    @ViewBuilder
    func floatingBars(top: some View, bottom: some View) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0) { top }
                .safeAreaBar(edge: .bottom, spacing: 0) { bottom }
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            safeAreaInset(edge: .top, spacing: 0) {
                top.background {
                    LinearGradient(colors: [Palette.background, Palette.background.opacity(0)], startPoint: .center, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottom.background {
                    LinearGradient(colors: [Palette.background.opacity(0), Palette.background], startPoint: .top, endPoint: .center)
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// A floating control's surface: the system's glass from iOS 26, the outlined page colour before.
    @ViewBuilder
    func floatingGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(Palette.background, in: shape)
                .overlay(shape.stroke(Palette.stroke))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        }
    }

    /// From iOS 26 the search field sits at the bottom, by the keyboard, as the system's own apps have it.
    @ViewBuilder
    func searchFieldAtBottom() -> some View {
        if #available(iOS 26.0, *) {
            toolbar { DefaultToolbarItem(kind: .search, placement: .bottomBar) }
        } else {
            self
        }
    }

    /// A list row with no fill, separator or selection inset (headers, notes).
    func plainRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// The drawer's list look, on the main list and the archive.
    func sessionList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 44)
            .scrollDismissesKeyboard(.immediately)
    }

    func reportsFrame(_ id: String, to frames: DrawerRowFrames) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.set($0, of: id) }
            .onAppear { frames.setShown(id, true) }
            .onDisappear { frames.setShown(id, false) }
    }
}
