import SwiftUI

/// The ＋ tray, one for the new-conversation and the conversation layouts: large
/// buttons for what goes into a message and the connectors, then the model, thinking
/// and access mode, then references, commands and the session's other modes.
/// Everything typing `/` or `@` reaches is here, for keyboards where those
/// characters sit a page away.
struct ComposerTray: View {
    let model: SessionModel
    let context: ComposerContext
    let camera: () -> Void
    let photos: () -> Void
    let files: () -> Void
    let pick: (Candidate) -> Void
    let setPermission: (String) -> Void
    /// In a popover (a wide window), which takes its height from the tray: the first page's rows
    /// for a Bot's or a group's, room for a page of the tray otherwise.
    var popover = false
    /// A Bot's chat or a group chat: the model and modes are not this session's to set.
    @Environment(\.botComposer) private var bot
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingPermission: String?
    @State private var confirmingTeamOff = false
    @State private var showingConnectors = false
    /// How tall the first page's rows are (`FittedTrayHeight`), from iOS 18.
    @State private var contentHeight: CGFloat?
    /// At full height: dragged there, or a page of the tray pushed.
    @State private var expanded = false

    private var composer: ComposerModel { model.composer }

    /// A Bot's or a group's tray is a few rows, not the half screen an ordinary conversation's
    /// fills: the sheet is as tall as they are, rather than ending in an empty half.
    private var fitted: PresentationDetent? {
        guard bot != nil, let contentHeight else { return nil }
        return .height(contentHeight)
    }

    private var popoverHeight: CGFloat? {
        guard popover else { return nil }
        if !expanded, bot != nil, let contentHeight { return contentHeight }
        return 520
    }

    private var detent: Binding<PresentationDetent> {
        Binding(get: { expanded ? .large : fitted ?? .medium }, set: { expanded = $0 == .large })
    }

    /// The pages the tray leads to are lists of their own: a sheet sized to the first page's
    /// rows opens to full height for them.
    private func expandsFitted(_ page: some View) -> some View {
        page.onAppear { if fitted != nil { expanded = true } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        TrayTile(title: "相机", systemImage: "camera", action: camera)
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        TrayTile(title: "照片", systemImage: "photo.on.rectangle", action: photos)
                        TrayTile(title: "文件", systemImage: "folder", action: files)
                        // Ordinary conversations and Bots both reach the connected services.
                        // A button, not a link: a link would take the whole row's taps.
                        TrayTile(title: "连接器", systemImage: "point.3.connected.trianglepath.dotted") { showingConnectors = true }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                // A Bot's model, thinking level and permission are its own, set on its page;
                // a group's members each answer on theirs.
                if bot == nil { modelSettings }
                Section {
                    NavigationLink {
                        expandsFitted(CandidateList(model: model, context: context, trigger: "@", pick: pick))
                    } label: {
                        Label(bot == nil ? "引用文件或对话" : "提到 Bot、文件或对话", systemImage: "at")
                    }
                    if bot == nil {
                        NavigationLink {
                            CandidateList(model: model, context: context, trigger: "/", leading: composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pick: pick)
                        } label: {
                            Label("指令", systemImage: "command")
                        }
                    } else {
                        // DSH's commands set this session's model, mode and goal, which a Bot
                        // keeps as its own; what a Bot is given to do on a schedule is here.
                        if case .bot(let id) = bot {
                            // A quick question answered from the chat so far, kept out of it.
                            Button {
                                dismiss()
                                app.botTeam.sideChatRequest = id
                            } label: {
                                Label("旁支提问", systemImage: "bubble.left.and.text.bubble.right")
                            }
                            .foregroundStyle(Palette.ink)
                        }
                        Button {
                            dismiss()
                            app.botTeam.scheduleRequest = bot
                        } label: {
                            Label("定时任务", systemImage: "clock")
                        }
                        .foregroundStyle(Palette.ink)
                    }
                }
                .groupedRow()
                if bot == nil { sessionModes }
            }
            .groupedList()
            .modifier(FittedTrayHeight(height: $contentHeight))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingConnectors) { expandsFitted(BotConnectorsPage().settingsStyle()) }
        }
        .frame(height: popoverHeight)
        .inkTint()
        .permissionConfirmation($confirmingPermission, confirm: setPermission)
        .alert("确认停用智能体团队协作？", isPresented: $confirmingTeamOff) {
            Button("取消", role: .cancel) {}
            Button("确认停用", role: .destructive) { composer.setTeam(false) }
        } message: {
            Text("停用后，共享任务工具和团队协调指令不再提供给智能体。这可能影响缓存复用、增加后续的 token 用量，并影响当前任务的协作效果。")
        }
        .presentationDetents([fitted ?? .medium, .large], selection: detent)
        .presentationDragIndicator(.visible)
        .sheetNotices()
    }

    /// An ordinary conversation: the model it answers with, whether it thinks, and what it may touch.
    private var modelSettings: some View {
        Section {
            NavigationLink {
                ModelSearchList(model: model, context: context)
            } label: {
                LabeledContent {
                    Text(context.modelName(model)).lineLimit(1)
                } label: {
                    Label("模型", systemImage: "cpu")
                }
            }
            if let thinking = context.thinking(model) {
                Toggle(isOn: Binding(get: { thinking.isOn }, set: { on in
                    Haptics.select()
                    Task { await model.selectModel(thinking.choice, effort: on ? thinking.on : thinking.off) }
                })) {
                    Label("思考", systemImage: "lightbulb")
                }
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

    /// An ordinary conversation: this session's other modes.
    private var sessionModes: some View {
        Section {
            if context.hasPlanMode || composer.planActive {
                Toggle(isOn: Binding(get: { composer.planActive }, set: { on in Haptics.select(); composer.setPlan(on) })) {
                    Label("计划模式", systemImage: "list.bullet.clipboard")
                }
                .disabled(composer.planSwitching)
            }
            // A child is a member of its root's team, not a team of its own.
            if let team = composer.teamEnabled, model.subagentAddress == nil {
                Toggle(isOn: Binding(get: { team }, set: { chooseTeam($0) })) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("智能体团队协作")
                            Text("用共享任务板协调多个智能体的分工，复杂任务表现更好，token 开销也更高。")
                                .font(.caption).foregroundStyle(Palette.secondary)
                        }
                    } icon: {
                        // The widest of the tray's symbols: a size down keeps it in the icon column.
                        Image(systemName: "person.3").imageScale(.small)
                    }
                }
                .disabled(composer.teamSwitching || composer.projection("modelSelection").isNull)
            }
        }
        .groupedRow()
    }

    private func chooseTeam(_ on: Bool) {
        Haptics.select()
        if !on, composer.teamDisableNeedsConfirmation {
            confirmingTeamOff = true
        } else {
            composer.setTeam(on)
        }
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

/// The height the tray's first page needs to show all its rows, insets included: from iOS 18,
/// which reports a list's scroll geometry. Before it, the tray keeps the half-screen sheet.
private struct FittedTrayHeight: ViewModifier {
    @Binding var height: CGFloat?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                (geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom).rounded(.up)
            } action: { _, new in
                LayoutLoopGuard.tick("ComposerTray.height")
                if new > 0 { height = new }
            }
        } else {
            content
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
                // Four to a row: a longer word in another language shrinks a little rather than wraps.
                Text(title).font(.footnote).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(enabled ? Palette.ink : Palette.faint)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
