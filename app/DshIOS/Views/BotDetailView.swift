import SwiftUI

/// A Bot's page, drawn as 设置 is: who it is and how it works (all editable here), with its
/// scheduled tasks and what it remembers one tap further in.
struct BotDetailView: View {
    /// The page to open on: the Bot's own page, or straight into one of the two under it.
    enum Tab: String, Hashable {
        case profile, schedules, memory
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let botId: String
    /// The pages pushed on the Bot's own.
    @State private var path: [Tab]
    @State private var appearanceOpen = false
    @State private var schedules: BotSchedules
    @State private var confirmingDelete = false
    @State private var exchange: BotExchangePair?

    init(botId: String, tab: Tab = .profile) {
        self.botId = botId
        _path = State(initialValue: tab == .profile ? [] : [tab])
        _schedules = State(initialValue: BotSchedules(target: .bot(botId)))
    }

    var body: some View {
        let team = app.botTeam
        NavigationStack(path: $path) {
            Group {
                if let bot = team.bot(botId) {
                    List {
                        Section { header(bot) }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        profile(bot)
                    }
                    .groupedList()
                    .sheet(isPresented: $appearanceOpen) { BotAppearanceSheet(botId: bot.id) }
                    .sheet(item: $exchange) { BotExchangeSheet(pair: $0) }
                    .confirmationDialog("删除\(bot.name)？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("删除", role: .destructive) { Task { await delete(bot) } }
                    } message: {
                        Text("它的私聊、记忆和定时任务都会删掉，它也会退出所有群聊。")
                    }
                } else {
                    ContentUnavailableView("这个 Bot 已不在团队里", systemImage: "person.slash")
                }
            }
            .navigationTitle(team.bot(botId)?.name ?? String(localized: "Bot"))
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
            .navigationDestination(for: Tab.self) { page in
                switch page {
                case .schedules: BotSchedulesPage(schedules: schedules)
                case .memory: BotMemoryPage(botId: botId)
                case .profile: EmptyView()
                }
            }
            // Inside the stack: the new-task sheet is one of this page's, drawn as it is.
            .botSchedules(schedules, app: app)
        }
        .settingsStyle()
    }

    /// The Bot's face, what it is for, and what it is up to. A tap on the face changes it.
    private func header(_ bot: BotInfo) -> some View {
        let team = app.botTeam
        return VStack(spacing: 8) {
            Button { appearanceOpen = true } label: {
                BotAvatar(bot: bot, size: 88, live: true)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil").font(.system(size: 12, weight: .bold)).foregroundStyle(.primary)
                            .frame(width: 28, height: 28).background(Color(.secondarySystemGroupedBackground), in: Circle())
                            .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 2))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更换头像")
            if !bot.role.isEmpty { Text(bot.role).font(.subheadline).foregroundStyle(.secondary) }
            if let doing = team.doingText(bot.id) {
                HStack(spacing: 5) {
                    if team.isWorking(bot.id) { StatusDot(state: .running, size: 6) }
                    Text(doing).font(.footnote).foregroundStyle(team.isWorking(bot.id) ? Palette.running : Palette.waiting).lineLimit(2)
                }
            } else if team.isMain(bot) {
                Text("主 Bot，负责接活和分派").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func row(_ title: LocalizedStringKey, _ icon: String, _ value: String = "") -> some View {
        LabeledContent {
            Text(value).lineLimit(1)
        } label: {
            Label(title, systemImage: icon)
        }
    }

    @ViewBuilder
    private func profile(_ bot: BotInfo) -> some View {
        let team = app.botTeam
        Section {
            NavigationLink {
                BotTextPage(title: "名字", value: bot.name, limit: 40, placeholder: "名字") { await team.update(bot, ["name": .string($0)]) }
            } label: { row("名字", "person.text.rectangle", bot.name) }
            NavigationLink {
                BotTextPage(title: "角色", value: bot.role, limit: 24, placeholder: "比如：研究员、文案", optional: true,
                            note: "一句话说清它负责什么。改了之后它会收到通知，按新角色继续。") { await team.update(bot, ["role": .string($0)]) }
            } label: { row("角色", "briefcase", bot.role.isEmpty ? String(localized: "未填写") : bot.role) }
            NavigationLink {
                BotTextPage(title: "工作说明", value: bot.instructions, multiline: true, placeholder: "它做事时要遵守的要求、偏好和背景", optional: true,
                            note: "每一轮工作都会先读这段说明。改了之后它会收到通知，按新说明继续。") { await team.update(bot, ["instructions": .string($0)]) }
            } label: {
                row("工作说明", "doc.text", bot.instructions.isEmpty ? String(localized: "未填写") : ToolCall.firstLine(bot.instructions))
            }
        }
        Section {
            NavigationLink { BotModelPage(botId: bot.id) } label: {
                row("模型", "cpu", team.modelName(bot.model) ?? String(localized: "未选择"))
            }
            if bot.model != nil {
                NavigationLink { BotEffortPage(botId: bot.id) } label: {
                    row("思考强度", "brain", team.effortName(of: bot) ?? String(localized: "模型默认"))
                }
            }
            if !team.permissionOptions.isEmpty {
                NavigationLink { BotPermissionPage(botId: bot.id) } label: {
                    row("权限", "lock.shield", team.permissionName(bot.permission) ?? "")
                }
            }
            NavigationLink { BotFolderPage(target: .bot(bot.id)) } label: {
                row("工作文件夹", "folder", bot.workDir.map { ($0 as NSString).lastPathComponent } ?? String(localized: "团队工作区"))
            }
        } header: {
            Text("工作方式")
        }
        Section {
            NavigationLink(value: Tab.schedules) {
                row("定时任务", "clock", schedules.loaded && !schedules.tasks.isEmpty ? String(localized: "\(schedules.tasks.count) 个") : "")
            }
            if team.team["memory"].bool != false {
                NavigationLink(value: Tab.memory) { row("记忆", "brain.head.profile") }
            }
        }
        capabilities(bot)
        connectors(bot)
        if team.bots.count > 1 {
            Section {
                ForEach(team.bots.filter { $0.id != bot.id }) { other in
                    Button { exchange = BotExchangePair(a: bot.id, b: other.id) } label: {
                        HStack(spacing: 12) {
                            BotAvatar(bot: other, size: 28)
                            Text(other.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: { Text("和别的 Bot 的往来") } footer: { Text("Bot 之间交代、回复的话不出现在它和你的聊天里，在这里看。") }
        }
        Section {
            if team.isMain(bot) {
                if team.mainBotIds.count > 1 {
                    if bot.id != team.mainBotId {
                        // The first main Bot is the one the sidebar and new requests reach.
                        Button("设为首要主 Bot") { Task { await team.run("set-main", ["id": .string(bot.id), "main": true, "primary": true]) } }
                    }
                    Button("不再作为主 Bot") { Task { await team.run("set-main", ["id": .string(bot.id), "main": false]) } }
                }
            } else {
                Button("设为主 Bot") { Task { await team.run("set-main", ["id": .string(bot.id), "main": true]) } }
            }
            // A fresh session for the chat, with a handoff note: the context starts small again,
            // the memory and the earlier parts stay.
            Button("开始新的一段对话") {
                Task {
                    if await team.run("bot-new-part", ["botId": .string(bot.id)]) {
                        Haptics.success()
                        app.showToast(String(localized: "已开始新的一段，之前的对话还能往上翻到"))
                    }
                }
            }
            .disabled(team.isWorking(bot.id))
            Button("复制一份") {
                Task {
                    if await team.duplicate(bot) {
                        Haptics.success()
                        app.showToast(String(localized: "已复制\(bot.name)"))
                    }
                }
            }
        } footer: {
            if team.isMain(bot) {
                Text("主 Bot 接下你交代的事，再分给合适的 Bot。主 Bot 不能删除，要删先把别的 Bot 设为主 Bot。")
            }
        }
        Section {
            Button("删除这个 Bot", role: .destructive) { confirmingDelete = true }
                .disabled(team.isMain(bot))
        }
        Section {
            Button { dismiss(); app.webRequest = UUID() } label: {
                Text("在 DSH 网页中打开").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            Link(destination: BotModel.websiteURL) {
                HStack(spacing: 4) {
                    Text("此 Bot 由 DS Bot 驱动")
                    Image(systemName: "arrow.up.right").font(.caption2.weight(.semibold))
                }
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Palette.control, in: Capsule())
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// The team's capabilities this Bot may use, each switched on or off here.
    @ViewBuilder
    private func capabilities(_ bot: BotInfo) -> some View {
        let team = app.botTeam
        Section {
            ForEach(team.capabilities, id: \.["name"]) { item in
                let name = item["name"].string ?? ""
                let status = team.capabilityStatus(name, of: bot)
                Toggle(isOn: Binding(get: { bot.capabilities.contains(name) }, set: { on in
                    Task { await team.run("bot-capability", ["botId": .string(bot.id), "name": .string(name), "attached": .bool(on)]) }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                        if let error = status["error"].string, status["state"].string == "error" {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                        } else if let detail = item["description"].string, !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            NavigationLink { BotCapabilitiesPage() } label: {
                Label(team.capabilities.isEmpty ? "添加能力" : "管理能力库", systemImage: "puzzlepiece")
            }
        } header: {
            Text("能力")
        } footer: {
            Text("MCP 服务、技能说明或它们的组合，整个团队共用一个能力库。")
        }
    }

    /// The connected services this Bot may use.
    @ViewBuilder
    private func connectors(_ bot: BotInfo) -> some View {
        let team = app.botTeam
        let connected = team.connectors.filter { $0["state"].string == "ready" || $0["state"].string == "connecting" }
        Section {
            ForEach(connected, id: \.["id"]) { row in
                let off = Set(row["offFor"].array.compactMap(\.string))
                Toggle(row["name"].string ?? "", isOn: Binding(get: { !off.contains(bot.id) }, set: { on in
                    var next = off
                    if on { next.remove(bot.id) } else { next.insert(bot.id) }
                    Task { await team.run("connector-set", ["id": row["id"], "offFor": .array(next.sorted().map(JSON.string))]) }
                }))
            }
            NavigationLink { BotConnectorsPage() } label: {
                Label(connected.isEmpty ? "连接服务" : "管理连接器", systemImage: "point.3.connected.trianglepath.dotted")
            }
        } header: {
            Text("连接器")
        }
    }

    private func delete(_ bot: BotInfo) async {
        Haptics.firm()
        if await app.botTeam.run("delete-bot", ["id": .string(bot.id)]) {
            dismiss()
            app.botTeam.openRequest = BotOpenRequest(route: nil)
        }
    }
}

/// A Bot's scheduled tasks, on a page of their own under the Bot's.
struct BotSchedulesPage: View {
    let schedules: BotSchedules

    var body: some View {
        List { BotScheduleSection(schedules: schedules) }
            .groupedList()
            .navigationTitle("定时任务")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// What a Bot remembers: a summary, a way to ask or change it in plain words, the entries
/// themselves, and every change made to them.
struct BotMemoryPage: View {
    @Environment(AppModel.self) private var app
    let botId: String
    @State private var memory: JSON = .null
    @State private var memoryError: String?
    @State private var loading = false

    var body: some View {
        let bot = app.botTeam.bot(botId)
        let entries = memory["entries"].array
        List {
            MemorySummarySection(target: ["botId": .string(botId)], memory: $memory)
            MemoryAskSection(target: ["botId": .string(botId)]) { if !$0.isNull { memory = $0 } }
            Section {
                if loading && memory.isNull {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let memoryError {
                    Text(memoryError).font(.footnote).foregroundStyle(.red)
                } else if entries.isEmpty {
                    Text("\(bot?.name ?? "")还没有记住什么。跟它说「记住…」就会记下来。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry["text"].string ?? "")
                            Text(origin(of: entry)).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await forget(entry) } }
                        }
                        .contextMenu {
                            Button("删除", systemImage: "trash", role: .destructive) { Task { await forget(entry) } }
                        }
                    }
                }
            } header: {
                Text("\(bot?.name ?? "")记得的事")
            } footer: {
                if !entries.isEmpty { Text("左滑可以删除。") }
            }
            Section {
                NavigationLink { MemoryHistoryPage(target: ["botId": .string(botId)]) } label: {
                    Label("改动记录", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .groupedList()
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func origin(of entry: JSON) -> String {
        var parts: [String] = []
        parts.append(entry["by"].string == "user" ? String(localized: "你说的") : String(localized: "自己记的"))
        if entry["scope"].string == "team" { parts.append(String(localized: "全队共享")) }
        if let added = entry["added"].string { parts.append(added) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            memory = try await app.botTeam.call("memory-view", ["botId": .string(botId), "summarize": true])
            memoryError = nil
        } catch {
            memoryError = error.localizedDescription
        }
    }

    private func forget(_ entry: JSON) async {
        Haptics.firm()
        var payload: [String: JSON] = ["botId": .string(botId), "scope": entry["scope"], "text": entry["text"]]
        if let topic = entry["topic"].string { payload["topic"] = .string(topic) }
        do {
            memory = try await app.botTeam.call("memory-forget", .object(payload))
        } catch {
            app.showToast(error.localizedDescription, tone: .warning)
        }
    }
}
