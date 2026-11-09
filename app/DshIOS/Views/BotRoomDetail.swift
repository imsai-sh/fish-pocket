import SwiftUI

/// A group chat's page: its name and notice, who is in it and who speaks first,
/// its scheduled tasks, and stopping or deleting it.
struct RoomDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let roomId: String
    @State private var confirmingDelete = false
    @State private var adding = false
    @State private var confirmingFullAccess = false
    @State private var schedules: BotSchedules

    init(roomId: String) {
        self.roomId = roomId
        _schedules = State(initialValue: BotSchedules(target: .room(roomId)))
    }

    var body: some View {
        let team = app.botTeam
        NavigationStack {
            Group {
                if let room = team.room(roomId) {
                    List {
                        Section {
                            HStack(spacing: 14) {
                                RoomAvatar(room: room, size: 60)
                                Text("\(room.members.count) 个 Bot").font(.subheadline).foregroundStyle(Palette.secondary)
                            }
                            .listRowBackground(Color.clear)
                        }
                        .listRowSeparator(.hidden)
                        about(room)
                        members(room)
                        speaking(room)
                        if !team.permissionOptions.isEmpty { permission(room) }
                        BotScheduleSection(schedules: schedules)
                        manage(room)
                    }
                    .groupedList()
                    .sheet(isPresented: $adding) { RoomAddMembersSheet(roomId: room.id) }
                    .botSchedules(schedules, app: app)
                    .confirmationDialog("删除「\(team.name(of: room))」？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("删除群聊", role: .destructive) { Task { await delete(room) } }
                    } message: {
                        Text("群里的聊天记录和定时任务都会删掉，成员 Bot 不受影响。")
                    }
                } else {
                    ContentUnavailableView("这个群聊已经不在了", systemImage: "person.2.slash")
                }
            }
            .navigationTitle(team.room(roomId).map(team.name(of:)) ?? String(localized: "群聊"))
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
        }
    }

    @ViewBuilder
    private func about(_ room: RoomInfo) -> some View {
        let team = app.botTeam
        Section {
            NavigationLink {
                BotTextPage(title: "群名", value: room.named ? room.name : "", limit: 60, placeholder: "不填就用成员的名字", optional: true) {
                    await team.update(room, ["name": .string($0)])
                }
            } label: { LabeledContent("群名", value: team.name(of: room)) }
            NavigationLink {
                BotTextPage(title: "群公告", value: room.notice, limit: 2000, multiline: true, placeholder: "群里每个 Bot 发言前都会先读", optional: true) {
                    await team.update(room, ["notice": .string($0)])
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("群公告")
                    Text(room.notice.isEmpty ? String(localized: "未填写") : room.notice)
                        .font(.footnote).foregroundStyle(Palette.secondary).lineLimit(3)
                }
            }
        }
        .groupedRow()
    }

    @ViewBuilder
    private func members(_ room: RoomInfo) -> some View {
        let team = app.botTeam
        Section {
            ForEach(room.members, id: \.self) { id in
                let bot = team.bot(id)
                HStack(spacing: 12) {
                    BotAvatar(bot: bot, name: id, size: 32)
                    Text(bot?.name ?? id).foregroundStyle(Palette.ink)
                    if room.admin == id {
                        Text("群主").font(.caption2).foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.control, in: Capsule())
                    }
                    Spacer()
                    if team.isWorking(id) {
                        StatusDot(state: .running, size: 6)
                        Button("停下") {
                            Haptics.firm()
                            Task { await team.run("stop-member-work", ["roomId": .string(room.id), "botId": .string(id)]) }
                        }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                    }
                }
                .swipeActions {
                    if room.members.count > 2 {
                        Button("移出", role: .destructive) { Task { await team.update(room, ["remove": [.string(id)]]) } }
                    }
                }
            }
            if room.members.count < 12 && team.bots.contains(where: { !room.members.contains($0.id) }) {
                Button { adding = true } label: { Label("添加成员", systemImage: "plus") }
            }
        } header: {
            Text("成员")
        } footer: {
            Text("左滑可以移出成员。一个群至少两个、最多十二个 Bot。")
        }
        .groupedRow()
    }

    @ViewBuilder
    private func speaking(_ room: RoomInfo) -> some View {
        let team = app.botTeam
        Section {
            Picker("群主", selection: Binding(get: { room.admin ?? "" }, set: { id in
                Task { await team.update(room, ["admin": id.isEmpty ? .null : .string(id)]) }
            })) {
                Text("不设群主").tag("")
                ForEach(room.members, id: \.self) { id in Text(team.bot(id)?.name ?? id).tag(id) }
            }
            if room.admin != nil {
                Picker("谁先回复", selection: Binding(get: { room.mode }, set: { mode in
                    Task { await team.update(room, ["mode": .string(mode)]) }
                })) {
                    Text("群主先接，再点名").tag("admin")
                    Text("每个 Bot 轮流回复").tag("everyone")
                }
            }
        } header: {
            Text("发言")
        } footer: {
            Text(room.admin == nil
                 ? "没有群主时，你发的每条消息，群里的 Bot 都会轮流回复。"
                 : room.mode == "admin" ? "你发的消息先交给群主，群主再 @ 需要的成员。@ 某个 Bot 时直接交给它。" : "你发的每条消息，群主先回，其他 Bot 再轮流回复。")
        }
        .groupedRow()
    }

    @ViewBuilder
    private func permission(_ room: RoomInfo) -> some View {
        let team = app.botTeam
        Section {
            Picker("权限", selection: Binding(get: { room.permission ?? "" }, set: { value in
                if value == "danger-full-access" { confirmingFullAccess = true; return }
                Task { await team.update(room, ["permission": value.isEmpty ? .null : .string(value)]) }
            })) {
                Text("各用自己的权限").tag("")
                ForEach(team.permissionOptions, id: \.["value"]) { option in
                    Text(SettingsView.permissionName(option)).tag(option["value"].string ?? "")
                }
            }
        } footer: {
            Text("统一设了权限，群里的 Bot 在这个群里都按它工作。")
        }
        .groupedRow()
        .alert("让群里的 Bot 都用完全权限？", isPresented: $confirmingFullAccess) {
            Button("取消", role: .cancel) {}
            Button("启用", role: .destructive) { Task { await team.update(room, ["permission": "danger-full-access"]) } }
        } message: {
            Text("它们在这个群里改文件、跑命令都不再先问你。只在信任要做的事时使用。")
        }
    }

    @ViewBuilder
    private func manage(_ room: RoomInfo) -> some View {
        let team = app.botTeam
        let busy = room.members.contains(where: team.isWorking)
        Section {
            if busy {
                Button("让所有人停下") {
                    Haptics.firm()
                    Task { await team.run("stop-room-work", ["roomId": .string(room.id)]) }
                }
            }
            Button("删除群聊", role: .destructive) { confirmingDelete = true }
        }
        .groupedRow()
    }

    private func delete(_ room: RoomInfo) async {
        Haptics.firm()
        if await app.botTeam.run("delete-room", ["id": .string(room.id)]) {
            dismiss()
            app.botTeam.openRequest = BotOpenRequest(route: nil)
        }
    }
}

/// Bots to add to a group: the team's others.
private struct RoomAddMembersSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let roomId: String
    @State private var picked: Set<String> = []
    @State private var saving = false

    var body: some View {
        let team = app.botTeam
        let room = team.room(roomId)
        let others = team.bots.filter { !(room?.members.contains($0.id) ?? true) }
        NavigationStack {
            Form {
                Section {
                    ForEach(others) { bot in
                        Button {
                            if picked.contains(bot.id) { picked.remove(bot.id) } else { picked.insert(bot.id) }
                            Haptics.select()
                        } label: {
                            HStack(spacing: 12) {
                                BotAvatar(bot: bot, size: 32)
                                Text(bot.name).foregroundStyle(Palette.ink)
                                Spacer()
                                Image(systemName: picked.contains(bot.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(bot.id) ? Palette.ink : Palette.faint)
                            }
                        }
                    }
                } footer: {
                    if let room { Text("最多还能加 \(max(0, 12 - room.members.count)) 个。") }
                }
            }
            .navigationTitle("添加成员")
            .navigationBarTitleDisplayMode(.inline)
            .saveToolbar(canSave: !picked.isEmpty && (room.map { $0.members.count + picked.count <= 12 } ?? false), saving: saving, cancel: { dismiss() }) {
                guard let room else { return }
                saving = true
                Task {
                    let done = await team.update(room, ["add": .array(picked.map(JSON.string))])
                    saving = false
                    if done { dismiss() }
                }
            }
        }
    }
}
