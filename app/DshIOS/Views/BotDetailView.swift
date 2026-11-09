import SwiftUI

/// A Bot's page: who it is and how it works (all editable here), its scheduled tasks,
/// and what it remembers.
struct BotDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case profile, schedules, memory
        var id: String { rawValue }
        var title: String {
            switch self {
            case .profile: String(localized: "资料")
            case .schedules: String(localized: "定时任务")
            case .memory: String(localized: "记忆")
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let botId: String
    @State private var tab = Tab.profile
    @State private var memory: JSON = .null
    @State private var memoryError: String?
    @State private var loadingMemory = false
    @State private var appearanceOpen = false
    @State private var schedules: BotSchedules
    @State private var confirmingDelete = false

    init(botId: String) {
        self.botId = botId
        _schedules = State(initialValue: BotSchedules(target: .bot(botId)))
    }

    var body: some View {
        let team = app.botTeam
        NavigationStack {
            Group {
                if let bot = team.bot(botId) {
                    List {
                        Section {
                            header(bot).listRowBackground(Color.clear)
                            tabs.listRowBackground(Color.clear)
                        }
                        .listRowSeparator(.hidden)
                        switch tab {
                        case .profile: profile(bot)
                        case .schedules: BotScheduleSection(schedules: schedules)
                        case .memory: memorySection(bot)
                        }
                    }
                    .groupedList()
                    .sheet(isPresented: $appearanceOpen) { BotAppearanceSheet(botId: bot.id) }
                    .botSchedules(schedules, app: app)
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
        }
        .task(id: tab) { if tab == .memory { await loadMemory() } }
    }

    private func header(_ bot: BotInfo) -> some View {
        let team = app.botTeam
        return HStack(spacing: 14) {
            Button { appearanceOpen = true } label: {
                BotAvatar(bot: bot, size: 60)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ink)
                            .frame(width: 22, height: 22).background(Palette.control, in: Circle())
                            .overlay(Circle().stroke(Palette.background, lineWidth: 2))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更换头像")
            VStack(alignment: .leading, spacing: 4) {
                if !bot.role.isEmpty { Text(bot.role).font(.subheadline) }
                if team.isWorking(bot.id) {
                    HStack(spacing: 5) { StatusDot(state: .running, size: 6); Text("在干活").font(.caption).foregroundStyle(Palette.running) }
                } else if team.isMain(bot) {
                    Text("主 Bot，负责接活和分派").font(.caption).foregroundStyle(Palette.secondary)
                }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases) { item in
                Button { Haptics.select(); tab = item } label: {
                    Text(item.title)
                        .font(.subheadline.weight(tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? Palette.onInk : Palette.ink)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 34)
                        .background(tab == item ? Palette.ink : Palette.control, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func profile(_ bot: BotInfo) -> some View {
        let team = app.botTeam
        Section {
            NavigationLink {
                BotTextPage(title: "名字", value: bot.name, limit: 40, placeholder: "名字") { await team.update(bot, ["name": .string($0)]) }
            } label: { LabeledContent("名字", value: bot.name) }
            NavigationLink {
                BotTextPage(title: "角色", value: bot.role, limit: 24, placeholder: "比如：研究员、文案", optional: true,
                            note: "一句话说清它负责什么。改了之后它会收到通知，按新角色继续。") { await team.update(bot, ["role": .string($0)]) }
            } label: { LabeledContent("角色", value: bot.role.isEmpty ? String(localized: "未填写") : bot.role) }
            NavigationLink {
                BotTextPage(title: "工作说明", value: bot.instructions, multiline: true, placeholder: "它做事时要遵守的要求、偏好和背景", optional: true,
                            note: "每一轮工作都会先读这段说明。改了之后它会收到通知，按新说明继续。") { await team.update(bot, ["instructions": .string($0)]) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("工作说明")
                    if !bot.instructions.isEmpty {
                        Text(bot.instructions).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(3)
                    }
                }
            }
        }
        .groupedRow()
        Section {
            NavigationLink { BotModelPage(botId: bot.id) } label: {
                LabeledContent("模型", value: team.modelName(bot.model) ?? String(localized: "未选择"))
            }
            if bot.model != nil {
                NavigationLink { BotEffortPage(botId: bot.id) } label: {
                    LabeledContent("思考强度", value: team.effortName(of: bot) ?? String(localized: "模型默认"))
                }
            }
            if !team.permissionOptions.isEmpty {
                NavigationLink { BotPermissionPage(botId: bot.id) } label: {
                    LabeledContent("权限", value: team.permissionName(bot.permission) ?? "")
                }
            }
        } header: {
            Text("工作方式")
        }
        .groupedRow()
        Section {
            if team.isMain(bot) {
                if team.mainBotIds.count > 1 {
                    Button("不再作为主 Bot") { Task { await team.run("set-main", ["id": .string(bot.id), "main": false]) } }
                }
            } else {
                Button("设为主 Bot") { Task { await team.run("set-main", ["id": .string(bot.id), "main": true]) } }
            }
            Button("复制一份") {
                Task {
                    if await team.duplicate(bot) {
                        Haptics.success()
                        app.showToast(String(localized: "已复制\(bot.name)"))
                    }
                }
            }
            Button("删除", role: .destructive) { confirmingDelete = true }
                .disabled(team.isMain(bot))
        } footer: {
            if team.isMain(bot) {
                Text("主 Bot 接下你交代的事，再分给合适的 Bot。主 Bot 不能删除，要删先把别的 Bot 设为主 Bot。")
            }
        }
        .groupedRow()
        Section {
            Button { dismiss(); app.webRequest = UUID() } label: {
                Text("在网页版中打开").font(.footnote).foregroundStyle(Palette.secondary)
            }
        }
        .listRowBackground(Color.clear)
    }

    private func delete(_ bot: BotInfo) async {
        Haptics.firm()
        if await app.botTeam.run("delete-bot", ["id": .string(bot.id)]) {
            dismiss()
            app.botTeam.openRequest = BotOpenRequest(route: nil)
        }
    }

    @ViewBuilder
    private func memorySection(_ bot: BotInfo) -> some View {
        let entries = memory["entries"].array
        Section {
            if loadingMemory && memory.isNull {
                ProgressView().frame(maxWidth: .infinity)
            } else if let memoryError {
                Text(memoryError).font(.footnote).foregroundStyle(Palette.removed)
            } else if entries.isEmpty {
                Text("\(bot.name)还没有记住什么。跟它说「记住…」就会记下来。").font(.footnote).foregroundStyle(Palette.secondary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry["text"].string ?? "").font(.subheadline)
                        Text(origin(of: entry)).font(.caption2).foregroundStyle(Palette.faint)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { Task { await forget(entry, of: bot) } }
                    }
                    .contextMenu {
                        Button("删除", systemImage: "trash", role: .destructive) { Task { await forget(entry, of: bot) } }
                    }
                }
            }
        } header: {
            Text("\(bot.name)记得的事")
        } footer: {
            if !entries.isEmpty { Text("左滑可以删除。") }
        }
        .groupedRow()
    }

    private func origin(of entry: JSON) -> String {
        var parts: [String] = []
        parts.append(entry["by"].string == "user" ? String(localized: "你说的") : String(localized: "自己记的"))
        if entry["scope"].string == "team" { parts.append(String(localized: "全队共享")) }
        if let added = entry["added"].string { parts.append(added) }
        return parts.joined(separator: " · ")
    }

    private func loadMemory() async {
        loadingMemory = true
        defer { loadingMemory = false }
        do {
            memory = try await app.botTeam.call("memory-view", ["botId": .string(botId)])
            memoryError = nil
        } catch {
            memoryError = error.localizedDescription
        }
    }

    private func forget(_ entry: JSON, of bot: BotInfo) async {
        Haptics.firm()
        var payload: [String: JSON] = ["botId": .string(bot.id), "scope": entry["scope"], "text": entry["text"]]
        if let topic = entry["topic"].string { payload["topic"] = .string(topic) }
        do {
            memory = try await app.botTeam.call("memory-forget", .object(payload))
        } catch {
            app.showToast(error.localizedDescription, tone: .warning)
        }
    }
}
