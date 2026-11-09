import SwiftUI

/// The ＋ tray, one for the new-conversation and the conversation layouts: three
/// large buttons for what goes into a message, then references, commands, the
/// model and the session's modes. Everything typing `/` or `@` reaches is here,
/// for keyboards where those characters sit a page away.
struct ComposerTray: View {
    let model: SessionModel
    let context: ComposerContext
    let camera: () -> Void
    let photos: () -> Void
    let files: () -> Void
    let pick: (Candidate) -> Void
    let setPermission: (String) -> Void
    @Environment(AppModel.self) private var app
    /// A Bot's chat or a group chat: the model and modes belong to the Bot, not to this session.
    @Environment(\.botComposer) private var bot
    @State private var confirmingPermission: String?

    private var composer: ComposerModel { model.composer }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        TrayTile(title: "相机", systemImage: "camera", action: camera)
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        TrayTile(title: "照片", systemImage: "photo.on.rectangle", action: photos)
                        TrayTile(title: "文件", systemImage: "folder", action: files)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    NavigationLink {
                        CandidateList(model: model, context: context, trigger: "@", pick: pick)
                    } label: {
                        Label("引用文件或对话", systemImage: "at")
                    }
                    NavigationLink {
                        CandidateList(model: model, context: context, trigger: "/", leading: composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pick: pick)
                    } label: {
                        Label("指令", systemImage: "command")
                    }
                    switch bot {
                    case nil:
                        NavigationLink {
                            ModelSearchList(model: model, context: context)
                        } label: {
                            LabeledContent {
                                Text(context.modelName(model)).lineLimit(1)
                            } label: {
                                Label("模型", systemImage: "cpu")
                            }
                        }
                    case .bot(let id):
                        // The Bot's own model: its every chat and group runs on it.
                        NavigationLink {
                            BotModelPage(botId: id)
                        } label: {
                            LabeledContent {
                                Text(app.botTeam.modelName(app.botTeam.bot(id)?.model) ?? String(localized: "未选择")).lineLimit(1)
                            } label: {
                                Label("模型", systemImage: "cpu")
                            }
                        }
                    case .room:
                        // Each member answers on its own model: the group has none to pick.
                        EmptyView()
                    }
                }
                .groupedRow()
                switch bot {
                case nil: sessionModes
                case .bot(let id): botModes(id)
                case .room: EmptyView()
                }
            }
            .groupedList()
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Palette.ink)
        .permissionConfirmation($confirmingPermission, confirm: { value in
            if case .bot(let id) = bot { setBotPermission(value, of: id) } else { setPermission(value) }
        })
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheetNotices()
    }

    /// A Bot's chat: its thinking level and permission, the same ones its page sets.
    @ViewBuilder
    private func botModes(_ id: String) -> some View {
        let team = app.botTeam
        if let bot = team.bot(id) {
            Section {
                if bot.model != nil {
                    NavigationLink {
                        BotEffortPage(botId: id)
                    } label: {
                        LabeledContent {
                            Text(team.effortName(of: bot) ?? String(localized: "模型默认")).lineLimit(1)
                        } label: {
                            Label("思考强度", systemImage: "lightbulb")
                        }
                    }
                }
                if !team.permissionOptions.isEmpty {
                    let current = bot.permission ?? team.defaultPermission ?? ""
                    Picker(selection: Binding(get: { current }, set: { value in
                        guard value != current else { return }
                        Haptics.select()
                        if ComposerView.needsConfirmation(value) { confirmingPermission = value } else { setBotPermission(value, of: id) }
                    })) {
                        ForEach(team.permissionOptions, id: \.["value"]) { option in
                            let value = option["value"].string ?? ""
                            Label(SettingsView.permissionName(option), systemImage: ComposerView.permissionIcon(value)).tag(value)
                        }
                    } label: {
                        Label("访问模式", systemImage: ComposerView.permissionIcon(current))
                    }
                    .pickerStyle(.menu)
                }
            } footer: {
                Text("改的是\(bot.name)自己的设置，它的私聊和群聊都按这个来。")
            }
            .groupedRow()
        }
    }

    private func setBotPermission(_ value: String, of id: String) {
        guard let bot = app.botTeam.bot(id) else { return }
        Task { await app.botTeam.update(bot, ["permission": .string(value)]) }
    }

    /// An ordinary conversation: this session's modes.
    private var sessionModes: some View {
        Section {
            if context.hasPlanMode || composer.planActive {
                Toggle(isOn: Binding(get: { composer.planActive }, set: { on in Haptics.select(); composer.setPlan(on) })) {
                    Label("计划模式", systemImage: "list.bullet.clipboard")
                }
                .toggleStyle(.mono)
                .disabled(composer.planSwitching)
            }
            if let thinking = context.thinking(model) {
                Toggle(isOn: Binding(get: { thinking.isOn }, set: { on in
                    Haptics.select()
                    Task { await model.selectModel(thinking.choice, effort: on ? thinking.on : thinking.off) }
                })) {
                    Label("思考", systemImage: "lightbulb")
                }
                .toggleStyle(.mono)
            }
            if !context.permissionOptions.isEmpty, model.permission != nil {
                Picker(selection: Binding(get: { model.permission ?? "" }, set: { choosePermission($0) })) {
                    ForEach(context.permissionOptions, id: \.value) { option in
                        Label(ComposerView.permissionTitle(option), systemImage: ComposerView.permissionIcon(option.value)).tag(option.value)
                    }
                } label: {
                    Label("访问模式", systemImage: ComposerView.permissionIcon(model.permission ?? ""))
                }
                .pickerStyle(.menu)
            }
        }
        .groupedRow()
    }

    private func choosePermission(_ value: String) {
        guard value != model.permission else { return }
        Haptics.select()
        if ComposerView.needsConfirmation(value) {
            confirmingPermission = value
        } else {
            setPermission(value)
        }
    }
}

/// A large button in the tray's first row.
private struct TrayTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 22))
                Text(title).font(.footnote)
            }
            .foregroundStyle(enabled ? Palette.ink : Palette.faint)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
