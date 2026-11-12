import PhotosUI
import SwiftUI

/// One text of a Bot or a group, edited on its own page: 保存 in the bar, the keyboard up.
struct BotTextPage: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let value: String
    var limit: Int?
    var multiline = false
    var placeholder: LocalizedStringKey = ""
    /// Empty is a value of its own (cleared), not a missing one.
    var optional = false
    var note: LocalizedStringKey?
    let save: (String) async -> Bool

    @State private var text = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let over = limit.map { trimmed.count > $0 } ?? false
        Form {
            Section {
                if multiline {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(6...)
                        .focused($focused)
                } else {
                    TextField(placeholder, text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { if canSave(trimmed, over: over) { commit(trimmed) } }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let note { Text(note) }
                    if let limit, over { Text("最多 \(limit) 个字").foregroundStyle(Palette.removed) }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .saveToolbar(canSave: canSave(trimmed, over: over), saving: saving) { commit(trimmed) }
        .onAppear { text = value; focused = true }
    }

    private func canSave(_ trimmed: String, over: Bool) -> Bool {
        !over && trimmed != value && (optional || !trimmed.isEmpty)
    }

    private func commit(_ trimmed: String) {
        saving = true
        Task {
            let done = await save(trimmed)
            saving = false
            if done { Haptics.success(); dismiss() }
        }
    }
}

/// The model a Bot runs on: the ones this DSH serves; keys and providers are set in 设置 › 模型.
struct BotModelPage: View {
    @Environment(AppModel.self) private var app
    let botId: String
    @State private var saving: String?

    var body: some View {
        let team = app.botTeam
        let bot = team.bot(botId)
        List {
            Section {
                ForEach(team.models, id: \.["ref"]) { model in
                    let ref = model["ref"].string ?? ""
                    Button {
                        guard let bot, ref != bot.model else { return }
                        saving = ref
                        Task {
                            await team.update(bot, ["model": .string(ref)])
                            saving = nil
                        }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model["name"].string ?? ref).foregroundStyle(Palette.ink)
                                HStack(spacing: 6) {
                                    if let provider = model["providerName"].string { Text(provider) }
                                    if model["needsKey"].bool == true { Text("缺少 API Key").foregroundStyle(Palette.removed) }
                                }
                                .font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            if saving == ref { ProgressView() } else if bot?.model == ref { Image(systemName: "checkmark").foregroundStyle(Palette.ink) }
                        }
                    }
                    .disabled(saving != nil)
                }
            } footer: {
                if let bot, bot.model != nil, bot.runningModel != bot.model {
                    Text("选的模型现在用不了，它暂时在用\(team.modelName(bot.runningModel) ?? "")。")
                }
            }
            .groupedRow()
            Section {
                NavigationLink { ModelProvidersPage() } label: { Label("添加模型或 API Key", systemImage: "plus") }
            } footer: {
                Text("模型和 API Key 跟普通会话共用一份设置。")
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
        // A key added in 设置 changes what the list can offer.
        .task(id: app.revision("llm/adapters-updated", "credentials/reference-updated", "credentials/record-updated")) {
            _ = try? await team.call("models")
            await team.refreshState()
        }
    }
}

/// How hard the Bot's model thinks: the levels that model offers.
struct BotEffortPage: View {
    @Environment(AppModel.self) private var app
    let botId: String
    @State private var levels: [JSON] = []
    @State private var fallback: String?
    @State private var loaded = false
    @State private var saving: String??

    var body: some View {
        let team = app.botTeam
        let bot = team.bot(botId)
        List {
            Section {
                row(id: nil, name: String(localized: "模型默认"), detail: fallback.map { level in levels.first { $0["id"].string == level }?["name"].string ?? level }, bot: bot)
                ForEach(levels, id: \.["id"]) { level in
                    row(id: level["id"].string, name: level["name"].string ?? "", detail: level["description"].string, bot: bot)
                }
            } footer: {
                if loaded && levels.isEmpty { Text("这个模型没有可选的思考强度。") }
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle("思考强度")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: bot?.runningModel) {
            guard let ref = bot?.runningModel, let value = try? await team.call("efforts", ["ref": .string(ref)]) else { loaded = true; return }
            levels = value["efforts"].array
            fallback = value["defaultEffort"].string
            loaded = true
        }
    }

    private func row(id: String?, name: String, detail: String?, bot: BotInfo?) -> some View {
        Button {
            guard let bot, id != bot.effort else { return }
            saving = .some(id)
            Task {
                await app.botTeam.update(bot, ["effort": id.map(JSON.string) ?? .null])
                saving = nil
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(Palette.ink)
                    if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Palette.secondary) }
                }
                Spacer()
                if saving == .some(id) { ProgressView() } else if bot?.effort == id { Image(systemName: "checkmark").foregroundStyle(Palette.ink) }
            }
        }
        .disabled(saving != nil)
    }
}

/// What the Bot may do without asking: DSH's permission presets.
struct BotPermissionPage: View {
    @Environment(AppModel.self) private var app
    let botId: String
    @State private var saving: String?
    @State private var confirmingFullAccess = false

    var body: some View {
        let team = app.botTeam
        let bot = team.bot(botId)
        let current = bot?.permission ?? team.defaultPermission
        List {
            Section {
                ForEach(team.permissionOptions, id: \.["value"]) { option in
                    let value = option["value"].string ?? ""
                    Button {
                        guard bot != nil, value != current else { return }
                        if value == "danger-full-access" { confirmingFullAccess = true } else { choose(value) }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SettingsView.permissionName(option)).foregroundStyle(Palette.ink)
                                if let detail = option["description"].string { Text(detail).font(.caption).foregroundStyle(Palette.secondary) }
                            }
                            Spacer()
                            if saving == value { ProgressView() } else if current == value { Image(systemName: "checkmark").foregroundStyle(Palette.ink) }
                        }
                    }
                    .disabled(saving != nil)
                }
            } footer: {
                Text("在它自己的私聊和群聊里都按这个权限工作；群聊另设了权限的，按群聊的。")
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle("权限")
        .navigationBarTitleDisplayMode(.inline)
        .alert("给\(bot?.name ?? "")完全权限？", isPresented: $confirmingFullAccess) {
            Button("取消", role: .cancel) {}
            Button("启用", role: .destructive) { choose("danger-full-access") }
        } message: {
            Text("它改文件、跑命令都不再先问你，包括定时任务到点时。只在信任它要做的事时使用。")
        }
    }

    private func choose(_ value: String) {
        guard let bot = app.botTeam.bot(botId) else { return }
        saving = value
        // Alone: the plugin checks a preset after the other fields of the same call.
        Task { await app.botTeam.update(bot, ["permission": .string(value)]); saving = nil }
    }
}

/// A Bot's look: a photo of its own, or its colour behind its initial.
struct BotAppearanceSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let botId: String
    @State private var photo: PhotosPickerItem?
    @State private var saving = false
    /// Photos used before (ds-bot's avatar library): `{id, name, image}`, newest first.
    @State private var library: [JSON] = []

    var body: some View {
        let team = app.botTeam
        NavigationStack {
            if let bot = team.bot(botId) {
                List {
                    Section {
                        HStack {
                            Spacer()
                            BotAvatar(bot: bot, size: 96, live: true)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                    Section {
                        PhotosPicker(selection: $photo, matching: .images) { Label("选一张照片", systemImage: "photo") }
                        if bot.avatarImage != nil || (team.isMain(bot) && !team.usesAppMark(bot)) {
                            Button(team.isMain(bot) && bot.id == team.mainBotId ? "恢复默认形象" : "移除照片", role: .destructive) {
                                save(bot, avatar: team.isMain(bot) && bot.id == team.mainBotId ? ["shape": "whale"] : .null)
                            }
                        }
                    }
                    .groupedRow()
                    if !library.isEmpty {
                        Section("用过的照片") {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                                ForEach(library, id: \.["id"]) { item in
                                    if let url = item["image"].string, let image = BotPicture.image(url) {
                                        Button { save(bot, avatar: ["image": .string(url)]) } label: {
                                            Image(uiImage: image).resizable().scaledToFill()
                                                .frame(width: 52, height: 52).clipShape(Circle())
                                                .overlay(Circle().stroke(Palette.ink, lineWidth: bot.avatarImage == url ? 2.5 : 0).padding(-3))
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button("从照片库移除", systemImage: "trash", role: .destructive) { Task { await remove(item) } }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .groupedRow()
                    }
                    Section {
                        BotLookPicker(shape: Binding(get: {
                            // A photo, or the main Bot's mascot, is none of these looks.
                            bot.avatarImage != nil || team.usesAppMark(bot) ? nil : team.character(of: bot).id
                        }, set: { shape in
                            if let shape { save(bot, avatar: ["shape": .string(shape)]) }
                        }), color: Binding(get: { bot.colorKey }, set: { key in if let key { colour(bot, key) } }))
                    } header: { Text("内置形象") } footer: { Text("选一个形状，再配一个颜色。") }
                    .groupedRow()
                }
                .groupedList()
                .disabled(saving)
                .navigationTitle("头像")
                .navigationBarTitleDisplayMode(.inline)
                .closeButton(dismiss)
                .onChange(of: photo) { _, item in
                    guard let item else { return }
                    Task {
                        defer { photo = nil }
                        guard let data = try? await item.loadTransferable(type: Data.self), let url = BotPicture.dataURL(from: data) else {
                            app.showToast(String(localized: "这张照片读不出来"), tone: .warning)
                            return
                        }
                        // Kept in the library too, for the team's other Bots.
                        _ = try? await team.call("avatar-import", ["items": [["name": "photo", "image": .string(url)]]])
                        save(bot, avatar: ["image": .string(url)])
                        await loadLibrary()
                    }
                }
                .task { await loadLibrary() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadLibrary() async {
        if let value = try? await app.botTeam.call("avatar-library", ["limit": 48]) { library = value["items"].array }
    }

    private func remove(_ item: JSON) async {
        _ = try? await app.botTeam.call("avatar-delete", ["id": item["id"]])
        await loadLibrary()
    }

    private func colour(_ bot: BotInfo, _ key: String) {
        guard key != bot.colorKey else { return }
        Haptics.select()
        Task { await app.botTeam.update(bot, ["color": .string(key)]) }
    }

    private func save(_ bot: BotInfo, avatar: JSON) {
        saving = true
        Task {
            await app.botTeam.update(bot, ["avatar": avatar])
            saving = false
        }
    }
}
