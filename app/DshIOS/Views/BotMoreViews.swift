import SwiftUI

// MARK: - Working folder

/// Where a Bot or a group works: the team workspace, or another workspace of this app.
/// A change moves the chat to a fresh part in the new folder at its next turn.
struct BotFolderPage: View {
    @Environment(AppModel.self) private var app
    let target: BotScheduleTarget
    @State private var folders: JSON = .null

    var body: some View {
        let team = app.botTeam
        let current: String? = switch target {
        case .bot(let id): team.bot(id)?.json["workDir"].string
        case .room(let id): team.room(id)?.json["workDir"].string
        }
        List {
            Section {
                row(title: String(localized: "团队工作区"), path: folders["team"].string, selected: current == nil) { choose("") }
                ForEach(folders["folders"].array, id: \.["path"]) { folder in
                    let path = folder["path"].string ?? ""
                    row(title: folder["title"].string ?? (path as NSString).lastPathComponent, path: path, selected: current == path) { choose(path) }
                }
            } footer: {
                Text("换了文件夹后，下一轮会在新文件夹里开始新的一段对话。要用别的文件夹，先在侧边栏新建或打开一个工作区。")
            }
            .groupedRow()
            if case .bot(let id) = target, let bot = team.bot(id) {
                Section {
                    Toggle("私有 Bot", isOn: Binding(get: { bot.json["private"].bool == true }, set: { on in
                        Task { await team.update(bot, ["private": .bool(on)]) }
                    }))
                } footer: {
                    Text("私有 Bot 只在自己的文件夹里工作，别的 Bot 和群聊都碰不到它的文件和记忆。它需要一个不和别人重叠的文件夹，不能是主 Bot，也不能在群聊里。")
                }
                .groupedRow()
            }
        }
        .groupedList()
        .navigationTitle("工作文件夹")
        .navigationBarTitleDisplayMode(.inline)
        .task { folders = (try? await team.call("folders")) ?? .null }
    }

    private func row(title: String, path: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Palette.ink)
                    if let path { Text(EnginePaths.display(path)).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.head) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Palette.ink) }
            }
        }
    }

    private func choose(_ path: String) {
        Task {
            switch target {
            case .bot(let id): if let bot = app.botTeam.bot(id) { await app.botTeam.update(bot, ["workDir": .string(path)]) }
            case .room(let id): if let room = app.botTeam.room(id) { await app.botTeam.update(room, ["workDir": .string(path)]) }
            }
        }
    }
}

// MARK: - Memory

/// Ask a Bot's (or a group's) memory a question, or tell it what to change, in plain words.
struct MemoryAskSection: View {
    @Environment(AppModel.self) private var app
    /// `["botId": …]` or `["roomId": …]`.
    let target: [String: JSON]
    let changed: (JSON) -> Void
    @State private var text = ""
    @State private var reply: JSON = .null
    @State private var asking = false

    var body: some View {
        Section {
            HStack(spacing: 8) {
                TextField("问它记得什么，或者让它记住、忘掉什么", text: $text, axis: .vertical).lineLimit(1...4)
                if asking { ProgressView() } else {
                    Button { ask() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let answer = reply["reply"].string {
                MarkdownView(text: answer)
                ForEach(Array(reply["changes"].array.enumerated()), id: \.offset) { _, change in
                    let verb = switch change["op"].string {
                    case "add": String(localized: "记下")
                    case "remove": String(localized: "忘掉")
                    default: String(localized: "改为")
                    }
                    Label("\(verb)：\(change["text"].string ?? "")", systemImage: change["ok"].bool == false ? "exclamationmark.triangle" : "checkmark")
                        .font(.caption).foregroundStyle(change["ok"].bool == false ? Palette.removed : Palette.secondary)
                }
            }
        } header: {
            Text("问问它的记忆")
        }
        .groupedRow()
    }

    private func ask() {
        asking = true
        var payload = target
        payload["text"] = .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            do {
                reply = try await app.botTeam.call("memory-ask", .object(payload))
                text = ""
                changed(reply["view"])
            } catch {
                app.showToast(BotErrorText.text(error.localizedDescription), tone: .warning)
            }
            asking = false
        }
    }
}

/// Every change to a memory, newest first; each can be undone.
struct MemoryHistoryPage: View {
    @Environment(AppModel.self) private var app
    let target: [String: JSON]
    @State private var rows: [JSON] = []
    @State private var more: JSON = .null
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && rows.isEmpty {
                Text("还没有改动").font(.footnote).foregroundStyle(Palette.secondary).groupedRow()
            }
            ForEach(rows, id: \.["id"]) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row["text"].string ?? "").font(.subheadline).strikethrough(row["op"].string == "remove")
                    Text(caption(row)).font(.caption2).foregroundStyle(Palette.faint)
                }
                .swipeActions {
                    if row["restored"].bool != true {
                        Button("撤销") { Task { await restore(row) } }.tint(Palette.ink)
                    }
                }
                .groupedRow()
            }
            if !more.isNull {
                Button("加载更早的") { Task { await load(before: more) } }.font(.footnote).groupedRow()
            }
        }
        .groupedList()
        .navigationTitle("改动记录")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load(before: .null) } }
    }

    private func caption(_ row: JSON) -> String {
        let op = switch row["op"].string {
        case "add": String(localized: "记下")
        case "remove": String(localized: "忘掉")
        default: String(localized: "改写")
        }
        let by = row["by"].string == "user" ? String(localized: "你") : (row["by"].string ?? "")
        let time = row["time"].string.flatMap { try? Date($0, strategy: .iso8601) }.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        var parts = [op, by, time]
        if row["restored"].bool == true { parts.append(String(localized: "已撤销")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func load(before: JSON) async {
        var payload = target
        if !before.isNull { payload["before"] = before }
        guard let value = try? await app.botTeam.call("memory-history", .object(payload)) else { loaded = true; return }
        rows += value["rows"].array
        more = value["more"]
        loaded = true
    }

    private func restore(_ row: JSON) async {
        var payload = target
        payload["id"] = row["id"]
        do {
            _ = try await app.botTeam.call("memory-restore", .object(payload))
            Haptics.success()
            rows = []
            more = .null
            await load(before: .null)
        } catch {
            app.showToast(BotErrorText.text(error.localizedDescription), tone: .warning)
        }
    }
}

/// A group's own memory: what every member reads there.
struct RoomMemoryPage: View {
    @Environment(AppModel.self) private var app
    let roomId: String
    @State private var memory: JSON = .null

    var body: some View {
        let target: [String: JSON] = ["roomId": .string(roomId)]
        List {
            MemoryAskSection(target: target) { memory = $0 }
            Section {
                let entries = memory["entries"].array
                if entries.isEmpty {
                    Text("群里还没有记下什么。").font(.footnote).foregroundStyle(Palette.secondary)
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    Text(entry["text"].string ?? "").font(.subheadline)
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await forget(entry) } }
                        }
                }
            } header: { Text("群里记得的事") }
            .groupedRow()
            Section { NavigationLink("改动记录") { MemoryHistoryPage(target: target) } }.groupedRow()
        }
        .groupedList()
        .navigationTitle("群记忆")
        .navigationBarTitleDisplayMode(.inline)
        .task { memory = (try? await app.botTeam.call("memory-view", .object(target))) ?? .null }
    }

    private func forget(_ entry: JSON) async {
        var payload: [String: JSON] = ["roomId": .string(roomId), "scope": entry["scope"], "text": entry["text"]]
        payload["topic"] = entry["topic"]
        memory = (try? await app.botTeam.call("memory-forget", .object(payload))) ?? memory
    }
}

// MARK: - Group goal

/// A goal the whole group works toward, stage by stage, led by its admin.
struct RoomGoalSection: View {
    @Environment(AppModel.self) private var app
    let room: RoomInfo
    /// The page presents these: a section's modifiers would reach every row.
    @Binding var drafting: Bool
    @Binding var confirmingStop: Bool

    var body: some View {
        let goal = room.json["goal"]
        Section {
            if goal.isNull {
                Button { drafting = true } label: { Label("设定目标", systemImage: "flag") }
                    .disabled(room.admin == nil)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(goal["title"].string ?? goal["brief"].string ?? "").font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer()
                        Text(Self.status(goal)).font(.caption).foregroundStyle(Palette.secondary)
                    }
                    let stages = goal["stages"].array
                    if !stages.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                                Capsule().fill(stage["status"].string == "passed" ? Palette.added : index == goal["current"].int ? Palette.running : Palette.control)
                                    .frame(height: 5)
                            }
                        }
                        if let index = goal["current"].int, index >= 0, index < stages.count {
                            let stage = stages[index]
                            Text("第 \(index + 1)/\(stages.count) 阶段：\(stage["title"].string ?? "")").font(.footnote)
                            ForEach(stage["tasks"].array, id: \.["id"]) { task in
                                let name = task["botId"].string.flatMap(app.botTeam.bot)?.name ?? ""
                                Label("\(name)：\(task["task"].string ?? "")", systemImage: task["status"].string == "done" || task["status"].string == "reported" ? "checkmark.circle" : "circle")
                                    .font(.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                            }
                        }
                    }
                    if let objective = goal["objective"].string, !objective.isEmpty {
                        Text(objective).font(.caption).foregroundStyle(Palette.faint).lineLimit(3)
                    }
                }
                switch goal["status"].string {
                case "active":
                    Button("暂停") { control("pause") }
                    Button("停止目标", role: .destructive) { confirmingStop = true }
                case "paused":
                    Button("继续") { control("resume") }
                    Button("停止目标", role: .destructive) { confirmingStop = true }
                case "drafting":
                    Button("取消", role: .destructive) { control("clear") }
                default:
                    Button("清除，设定新目标") { control("clear") }
                }
            }
        } header: {
            Text("群目标")
        } footer: {
            if goal.isNull {
                Text(room.admin == nil ? "设定目标需要先设一个群主。" : "说一个整个群要达成的结果，群主会和你对齐细节，再分阶段带着成员推进。")
            }
        }
        .groupedRow()
    }

    static func status(_ goal: JSON) -> String {
        switch goal["status"].string {
        case "drafting": String(localized: "正在和你对齐")
        case "active": goal["idle"].bool == true ? String(localized: "等你回复") : String(localized: "进行中")
        case "paused": String(localized: "已暂停")
        case "complete": String(localized: "已达成")
        case "stopped": String(localized: "已停止")
        default: ""
        }
    }

    private func control(_ action: String) { Self.control(action, room: room, team: app.botTeam) }

    @MainActor
    static func control(_ action: String, room: RoomInfo, team: BotModel) {
        Task { await team.run("goal-control", ["roomId": .string(room.id), "goalId": room.json["goal"]["id"], "action": .string(action)]) }
    }
}

struct GoalDraftSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let roomId: String
    @State private var text = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("这个群要达成什么？", text: $text, axis: .vertical).lineLimit(4...)
                } footer: {
                    Text("群主会先问你几个关键问题，确认后拆成阶段，分给成员去做。")
                }
            }
            .navigationTitle("设定目标")
            .navigationBarTitleDisplayMode(.inline)
            .saveToolbar(canSave: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 2000, saving: saving, cancel: { dismiss() }) {
                saving = true
                Task {
                    if await app.botTeam.run("goal-draft", ["roomId": .string(roomId), "text": .string(text)]) { dismiss() }
                    saving = false
                }
            }
        }
    }
}

// MARK: - Usage

/// Tokens the team spent, by Bot and by model, from ds-bot's ledger.
struct BotUsagePage: View {
    enum Span: Int, CaseIterable, Identifiable { case day = 1, week = 7, month = 30; var id: Int { rawValue } }

    @Environment(AppModel.self) private var app
    @State private var usage: JSON = .null
    @State private var span = Span.week

    var body: some View {
        let totals = self.totals
        List {
            Section {
                Picker("范围", selection: $span) {
                    Text("今天").tag(Span.day)
                    Text("7 天").tag(Span.week)
                    Text("30 天").tag(Span.month)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("输入", value: TimelineFormat.compact(totals.input))
                LabeledContent("缓存命中", value: TimelineFormat.compact(totals.cached))
                LabeledContent("输出", value: TimelineFormat.compact(totals.output))
                LabeledContent("调用次数", value: "\(totals.calls)")
            }
            .groupedRow()
            Section("按 Bot") {
                ForEach(totals.byOwner, id: \.name) { entry in LabeledContent(entry.name, value: TimelineFormat.compact(entry.tokens)) }
            }
            .groupedRow()
            Section("按模型") {
                ForEach(totals.byModel, id: \.name) { entry in LabeledContent(entry.name, value: TimelineFormat.compact(entry.tokens)) }
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle("用量")
        .navigationBarTitleDisplayMode(.inline)
        .task { usage = (try? await app.botTeam.call("usage", ["timeZone": .string(TimeZone.current.identifier)])) ?? .null }
    }

    private struct Totals {
        var input = 0, cached = 0, output = 0, calls = 0
        var byOwner: [(name: String, tokens: Int)] = []
        var byModel: [(name: String, tokens: Int)] = []
    }

    private var totals: Totals {
        var totals = Totals()
        let owners = usage["owners"].array, models = usage["models"].array
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH"
        let now = usage["now"].string.flatMap(formatter.date(from:)) ?? .now
        let from = now.addingTimeInterval(-Double(span.rawValue) * 86_400)
        var byOwner: [Int: Int] = [:], byModel: [Int: Int] = [:]
        for row in usage["rows"].array {
            let cells = row.array
            guard cells.count >= 9, let hour = cells[0].string.flatMap(formatter.date(from:)), hour > from else { continue }
            let input = cells[4].int ?? 0, cacheRead = cells[5].int ?? 0, cacheWrite = cells[6].int ?? 0, output = cells[7].int ?? 0
            totals.input += input + cacheWrite
            totals.cached += cacheRead
            totals.output += output
            totals.calls += cells[8].int ?? 0
            let tokens = input + cacheRead + cacheWrite + output
            byOwner[cells[1].int ?? -1, default: 0] += tokens
            byModel[cells[2].int ?? -1, default: 0] += tokens
        }
        totals.byOwner = byOwner.map { index, tokens in
            let owner = index >= 0 && index < owners.count ? owners[index] : .null
            let team = app.botTeam
            var name: String
            switch owner["kind"].string {
            case "other": name = String(localized: "其他会话")
            case "room": name = owner["id"].string.flatMap(team.room).map(team.name(of:)) ?? owner["name"].string ?? "?"
            default: name = owner["id"].string.flatMap(team.bot)?.name ?? owner["name"].string ?? "?"
            }
            if owner["deleted"].bool == true { name += String(localized: "（已删除）") }
            return (name, tokens)
        }.sorted { $0.tokens > $1.tokens }
        totals.byModel = byModel.map { index, tokens in
            let model = index >= 0 && index < models.count ? models[index] : .null
            return (model["name"].string ?? model["key"].string ?? "?", tokens)
        }.sorted { $0.tokens > $1.tokens }
        return totals
    }
}

// MARK: - Team workspace

/// The folder the team works in unless a Bot or group has its own.
struct BotWorkspacePage: View {
    @Environment(AppModel.self) private var app
    @State private var folders: JSON = .null

    var body: some View {
        let team = app.botTeam
        List {
            Section {
                LabeledContent("现在", value: folders["team"].string.map(EnginePaths.display) ?? "")
            } footer: { Text("没有单独设文件夹的 Bot 和群聊都在这里工作。") }
            .groupedRow()
            if !folders["folders"].array.isEmpty {
                Section("换成") {
                    ForEach(folders["folders"].array, id: \.["path"]) { folder in
                        Button(folder["title"].string ?? EnginePaths.display(folder["path"].string ?? "")) {
                            Task {
                                if await team.run("team-workspace", ["path": folder["path"]]) {
                                    folders = (try? await team.call("folders")) ?? folders
                                }
                            }
                        }
                    }
                }
                .groupedRow()
            }
        }
        .groupedList()
        .navigationTitle("团队工作区")
        .navigationBarTitleDisplayMode(.inline)
        .task { folders = (try? await team.call("folders")) ?? .null }
    }
}

// MARK: - Diagnostics

/// What went wrong in the Bot plugin lately, with a report to copy into an issue.
struct BotDiagnosticsPage: View {
    @Environment(AppModel.self) private var app
    @State private var value: JSON = .null

    var body: some View {
        let team = app.botTeam
        List {
            Section {
                Button("复制诊断报告") {
                    copyToPasteboard(value["markdown"].string ?? "")
                    app.showToast(String(localized: "已复制"))
                }
                .disabled(value["markdown"].string == nil)
                Button("清空记录", role: .destructive) {
                    Task { _ = try? await team.call("diagnostics-clear"); value = (try? await team.call("diagnostics")) ?? value }
                }
            } footer: { Text("报告里已经去掉密钥和个人路径，可以直接贴到问题反馈里。") }
            .groupedRow()
            Section("最近的问题") {
                if value["entries"].array.isEmpty { Text("没有记录到问题").font(.footnote).foregroundStyle(Palette.secondary) }
                ForEach(Array(value["entries"].array.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry["text"].string ?? "").font(.caption.monospaced()).lineLimit(6)
                        Text([entry["level"].string, entry["bot"].string, entry["time"].string].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(Palette.faint)
                    }
                }
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle("问题诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task { value = (try? await team.call("diagnostics", ["client": ["surface": "ios-native"]])) ?? .null }
    }
}

extension EnginePaths {
    /// An engine path for reading: the home folder as `~`.
    static func display(_ path: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
