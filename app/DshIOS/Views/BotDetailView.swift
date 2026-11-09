import SwiftUI

/// A Bot's details: who it is, and what it remembers.
struct BotDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case profile, memory
        var id: String { rawValue }
        var title: String {
            switch self {
            case .profile: String(localized: "资料")
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

    var body: some View {
        let team = app.botTeam
        NavigationStack {
            Group {
                if let bot = team.bot(botId) {
                    List {
                        Section {
                            HStack(spacing: 14) {
                                BotAvatar(bot: bot, size: 60)
                                VStack(alignment: .leading, spacing: 4) {
                                    if !bot.role.isEmpty { Text(bot.role).font(.subheadline) }
                                    if team.isWorking(bot.id) {
                                        HStack(spacing: 5) { StatusDot(state: .running, size: 6); Text("在干活").font(.caption).foregroundStyle(Palette.running) }
                                    }
                                }
                            }
                            .listRowBackground(Color.clear)
                            tabs.listRowBackground(Color.clear)
                        }
                        .listRowSeparator(.hidden)
                        switch tab {
                        case .profile: profile(bot)
                        case .memory: memorySection(bot)
                        }
                    }
                    .groupedList()
                } else {
                    ContentUnavailableView("这个 Bot 已不在团队里", systemImage: "person.slash")
                }
            }
            .navigationTitle(team.bot(botId)?.name ?? "Bot")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
        }
        .task(id: tab) { if tab == .memory { await loadMemory() } }
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
            LabeledContent("名字", value: bot.name)
            if !bot.role.isEmpty { LabeledContent("角色", value: bot.role) }
            if let model = bot.json["appliedModel"].string ?? bot.json["model"].string {
                let name = team.team["models"].array.first { $0["ref"].string == model }?["name"].string ?? model
                LabeledContent("模型", value: name)
            }
            if bot.id == team.mainBotId { LabeledContent("身份", value: String(localized: "主 Bot，负责接活和分派")) }
        }
        .groupedRow()
        if let instructions = bot.json["instructions"].string, !instructions.isEmpty {
            Section("工作说明") { Text(instructions).font(.subheadline) }.groupedRow()
        }
        Section {
            Button("在网页版管理定时任务、能力和连接器") { dismiss(); app.webRequest = UUID() }
                .font(.subheadline)
        } footer: {
            Text("改名、换模型、定时任务这些设置暂时在网页版里。")
        }
        .groupedRow()
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
