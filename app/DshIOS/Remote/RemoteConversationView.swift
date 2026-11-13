import SwiftUI

/// A session on one of the user's computers. It reads like a local conversation (the same
/// turns, tool rows and sheets) and says in its title whose it is: the agent and the machine.
/// What it can do follows the computer: offline it shows the history it has, and a session
/// that was started in the agent's own client stays read-only until it is taken over.
struct RemoteConversationView: View {
    let sessionId: String
    @Binding var selection: String?
    /// Opens the drawer; nil where the sidebar is always shown (iPad).
    var openDrawer: (() -> Void)?
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: RemoteSessionModel?
    @State private var atBottom = true
    @State private var timelineTop: CGFloat = 0
    @State private var detail: TimelineDetail?
    /// Requests swiped away; they stay answerable from the line above the composer.
    @State private var deferred: Set<String> = []
    @State private var panel: Panel?
    @State private var takeoverAsk: Bool?

    enum Panel: String, Identifiable {
        case options, info, changes, files
        var id: String { rawValue }
    }

    private static let bottomId = "remote-timeline-bottom"

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ConversationLoading().background(Palette.background)
                    .toolbar { if let openDrawer { ToolbarItem(placement: .topBarLeading) { DrawerButton(action: openDrawer) } } }
            }
        }
        .task(id: app.remote.signedIn) {
            guard model == nil, app.remote.signedIn else { return }
            // Kept from the last time it was open, it shows at once and catches up behind.
            model = app.remote.acquire(sessionId)
        }
        .onDisappear {
            guard model != nil else { return }
            model = nil
            app.remote.release(sessionId)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        Task { @MainActor in
            if animated {
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func content(_ model: RemoteSessionModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                RemoteTimelineList(model: model)
                    .modifier(LinkOpening())
                Color.clear.frame(height: 1).id(Self.bottomId)
            }
            .environment(\.timelineScroll, TimelineScroll(keep: { id in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    proxy.scrollTo(id, anchor: .top)
                }
            }, top: timelineTop))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { timelineTop = $0 }
            .modifier(TimelineAnchor())
            .modifier(BottomFollow(atBottom: $atBottom) { scrollToBottom(proxy, animated: false) })
            .scrollDismissesKeyboard(.immediately)
            .scrollBounceBehavior(.always)
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .onChange(of: model.rows.last?.id) { _, _ in
                if case .user? = model.rows.last { atBottom = true; scrollToBottom(proxy) }
            }
            .onChange(of: model.busy) { _, busy in if busy, atBottom { scrollToBottom(proxy) } }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if !atBottom, !model.rows.isEmpty {
                        FloatingIcon(systemName: "chevron.down", label: "回到底部") {
                            atBottom = true
                            scrollToBottom(proxy)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .animation(.snappy(duration: 0.18), value: atBottom)
            }
        }
        .background(Palette.background)
        .overlay { placeholder(model) }
        .conversationDock {
            dock(model)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .readableWidth()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { app.composerHeight = $0 }
        }
        .navigationTitle(model.meta?.displayTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .conversationBar()
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if let openDrawer {
                ToolbarItem(placement: .topBarLeading) { DrawerButton(action: openDrawer) }
            }
            if let meta = model.meta {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        app.remoteSessionRequest = RemoteSessionTarget(deviceId: meta.deviceId, agentId: meta.agentId, projectId: meta.projectId)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("在这台电脑上新建会话")
                }
            }
            ToolbarItem(placement: .principal) { RemoteTitleMenu(model: model) }
            ToolbarItem(placement: .topBarTrailing) { moreMenu(model) }
        }
        .environment(\.conversationActions, ConversationActions(
            openChanges: { panel = .changes },
            present: { item in
                deferred.formUnion(interactions(model).map(\.id))
                detail = item
            }
        ))
        .onChange(of: presented(model)?.id) { _, id in if id != nil { dismissKeyboard() } }
        .onChange(of: waiting(model)?.id) { old, new in if let new, new != old { Haptics.warning() } }
        .onChange(of: model.optionsRequest) { panel = .options }
        // Archived from here or from another device: the main view moves on, as with a local session.
        .onChange(of: model.meta?.archived) { _, archived in if archived == true { selection = nil } }
        // Read once it is on screen, and again when a turn ends while it is.
        .onChange(of: "\(model.meta?.unread == true)-\(scenePhase == .active)", initial: true) {
            if scenePhase == .active { app.remote.markRead(sessionId) }
        }
        .sheet(item: interactionBinding(model)) { sheet(for: $0, model) }
        .sheet(item: $panel) { panel in
            Group {
                switch panel {
                case .options: RemoteOptionsSheet(model: model)
                case .info: RemoteInfoSheet(model: model)
                case .changes: RemoteChangesSheet(model: model)
                case .files: RemoteFilesSheet(deviceId: model.meta?.deviceId ?? "", root: model.cwd ?? "")
                }
            }
            // These are pages to read and choose from, like 设置: the system's own lists.
            .environment(\.systemLists, true)
            .sheetNotices()
        }
        .alert(takeoverAsk == true ? "接管这个会话？" : "交还这个会话？", isPresented: Binding(get: { takeoverAsk != nil }, set: { if !$0 { takeoverAsk = nil } }), presenting: takeoverAsk) { enable in
            Button(enable ? "接管" : "交还") { Task { await model.setTakeover(enable) } }
            Button("取消", role: .cancel) {}
        } message: { enable in
            Text(takeoverMessage(enable, model))
        }
        .onChange(of: model.notice) { _, text in
            guard let text else { return }
            model.notice = nil
            app.showToast(text, tone: .warning)
        }
        .alert("出错了", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }

    private func takeoverMessage(_ enable: Bool, _ model: RemoteSessionModel) -> String {
        guard enable else { return String(localized: "交还后这里只能查看，不能发消息。") }
        if model.meta?.agentType == "dsh" { return String(localized: "接管后可以从这里发消息，电脑上的对话会同步更新。") }
        return String(localized: "接管后可以从这里发消息。电脑上的客户端可能要重启才能看到新内容，请不要两边同时操作这个会话。")
    }

    // MARK: Empty and failed states

    @ViewBuilder
    private func placeholder(_ model: RemoteSessionModel) -> some View {
        if case .failed(let message) = model.link, !model.loaded {
            VStack(spacing: 12) {
                Text("会话打不开").font(.headline)
                Text(message).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                Button("重试") { Task { await model.refresh() } }.buttonStyle(.capsule(.outline, height: 44, fill: false))
            }
            .padding(32)
        } else if !model.loaded {
            ConversationLoading()
        } else if model.rows.isEmpty {
            Text("还没有消息").font(.subheadline).foregroundStyle(Palette.secondary)
        }
    }

    // MARK: The bottom of the page

    @ViewBuilder
    private func dock(_ model: RemoteSessionModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let waiting = waiting(model) {
                Button { deferred.remove(waiting.id) } label: {
                    HStack(spacing: 6) {
                        StatusDot(state: .waiting)
                        Text(waiting.isApproval ? "等你允许" : "等你回答").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up").font(.caption2.weight(.bold)).foregroundStyle(Palette.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(Palette.waiting.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(model.notifications) { notice in RemoteNoticeLine(notice: notice, model: model) }
            if let block = model.sendBlock {
                let failed: Bool = if case .failed = model.link { true } else { false }
                RemoteBlockBar(text: block,
                               action: failed ? ("重试", { Task { await model.refresh() } })
                                   : model.loaded && model.online && !model.takeover && model.canToggleTakeover ? ("接管", { takeoverAsk = true }) : nil)
            } else if model.loaded {
                RemoteComposer(model: model, openOptions: { panel = .options })
                    .allowsHitTesting(presented(model) == nil)
            }
        }
    }

    private func moreMenu(_ model: RemoteSessionModel) -> some View {
        Menu {
            Section {
                Button { panel = .options } label: { Label("模型与权限", systemImage: "cpu") }
                    .disabled(!model.canChoose)
                Button { panel = .changes } label: { Label("改动的文件", systemImage: "doc.badge.gearshape") }
                Button { panel = .files } label: { Label("浏览项目文件", systemImage: "folder") }
                    .disabled(!model.online || (model.cwd ?? "").isEmpty)
            }
            Section {
                if model.takeover {
                    Button { takeoverAsk = false } label: { Label("交还给电脑", systemImage: "arrow.uturn.backward") }
                        .disabled(!model.canToggleTakeover)
                } else {
                    Button { takeoverAsk = true } label: { Label("接管会话", systemImage: "hand.raised") }
                        .disabled(!model.canToggleTakeover)
                }
                Button { Task { await model.refresh() } } label: { Label("重新同步", systemImage: "arrow.clockwise") }
                Button { panel = .info } label: { Label("会话信息", systemImage: "info.circle") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("更多")
    }

    // MARK: Requests and details

    enum Interaction: Identifiable {
        case notice(RemoteNotice)
        case plan(RemotePlan)
        case detail(TimelineDetail)

        var id: String {
            switch self {
            case .notice(let notice): "n-\(notice.id)"
            case .plan(let plan): "p-\(plan.id)"
            case .detail(let detail): "d-\(detail.id)"
            }
        }

        var isApproval: Bool {
            if case .notice(let notice) = self { return notice.isApproval }
            return false
        }
    }

    private func interactions(_ model: RemoteSessionModel) -> [Interaction] {
        guard model.current else { return [] }
        return model.interactions.map(Interaction.notice) + (model.plan.map { [Interaction.plan($0)] } ?? [])
    }

    private func presented(_ model: RemoteSessionModel) -> Interaction? {
        interactions(model).first { !deferred.contains($0.id) }
    }

    private func waiting(_ model: RemoteSessionModel) -> Interaction? {
        interactions(model).first { deferred.contains($0.id) }
    }

    private func interactionBinding(_ model: RemoteSessionModel) -> Binding<Interaction?> {
        Binding(
            get: { panel != nil ? nil : presented(model) ?? detail.map(Interaction.detail) },
            set: { value in
                guard value == nil else { return }
                if let shown = presented(model) { deferred.insert(shown.id) } else { detail = nil }
            }
        )
    }

    @ViewBuilder
    private func sheet(for interaction: Interaction, _ model: RemoteSessionModel) -> some View {
        switch interaction {
        case .notice(let notice):
            RemoteNoticeSheet(notice: notice, model: model)
        case .plan(let plan):
            RemotePlanSheet(plan: plan, model: model)
        case .detail(.tool(let call)):
            ToolDetailSheet(call: call, current: { model.toolCall($0) })
        case .detail(.reasoning(let id, let text)):
            ReasoningSheet(id: id, text: text, current: { model.reasoning($0) })
        case .detail(.usage(let usage)):
            TurnUsageSheet(usage: usage)
        case .detail(.text(let text)):
            SelectTextSheet(text: text)
        }
    }
}

/// The title of a remote conversation: its name over 「Codex · 书房的 Mac」, or how the
/// connection stands while it is not live. A tap opens the session's menu.
private struct RemoteTitleMenu: View {
    let model: RemoteSessionModel
    @Environment(AppModel.self) private var app

    private var subtitle: String {
        guard let meta = model.meta else { return "" }
        // A drop that mends itself in a moment is not worth a word: only one that lasts is said.
        switch model.link {
        case .connecting where model.struggling: return String(localized: "正在连接…")
        case .reconnecting where model.struggling: return String(localized: "正在重新连接…")
        case .failed: return String(localized: "连接失败")
        default: break
        }
        let place = "\(meta.agentTag) · \(app.remote.deviceName(of: meta))"
        return meta.deviceOnline ? place : String(localized: "\(place) · 离线")
    }

    var body: some View {
        let meta = model.meta
        Menu {
            if let meta {
                Button { app.renameRequest = RenameRequest(target: .session(RemoteStore.selection(meta.id)), initial: meta.title ?? "") } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button { change { await app.remote.setPinned(meta.id, !meta.pinned) } } label: {
                    Label(meta.pinned ? "取消置顶" : "置顶会话", systemImage: meta.pinned ? "pin.slash" : "pin")
                }
                Button { change { await app.remote.setArchived(meta.id, true) } } label: {
                    Label("归档会话", systemImage: "archivebox")
                }
                Button { copyToPasteboard(meta.id); app.showToast(String(localized: "已复制"), tone: .success) } label: {
                    Label("复制会话 ID", systemImage: "doc.on.doc")
                }
            }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(meta?.displayTitle ?? String(localized: "新会话")).font(.callout.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Palette.secondary)
                }
                Text(subtitle).font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 200)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .barTitleGlass()
        }
        .accessibilityLabel(Text("会话：\(meta?.displayTitle ?? "")，\(subtitle)"))
        .accessibilityHint("打开会话菜单")
    }

    private func change(_ work: @escaping () async -> String?) {
        Task {
            if let failure = await work() { app.showToast(failure, tone: .warning) }
        }
    }
}

/// The timeline. Its own view so that list updates, which redraw the page, do not re-diff every row.
private struct RemoteTimelineList: View {
    let model: RemoteSessionModel

    var body: some View {
        let turnOpen: Bool = if case .turn(let turn)? = model.rows.last { turn.inProgress } else { false }
        VStack(alignment: .leading, spacing: 20) {
            if model.hasOlder { RemoteLoadOlder(model: model) }
            ForEach(model.rows) { row in
                RemoteRowView(row: row, model: model).equatable().id(row.id)
            }
            // Busy before it has written anything of this turn: the step line alone.
            if model.busy, !turnOpen {
                AssistantTurnView(blocks: [], turn: nil, inProgress: true, startedAt: nil, endedAt: nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .readableWidth()
    }
}

private struct RemoteRowView: View, Equatable {
    let row: RemoteRow
    let model: RemoteSessionModel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row && lhs.model === rhs.model }

    var body: some View {
        switch row {
        case .user(let id, let text, let attachments, let delivery):
            RemoteUserBubble(id: id, text: text, attachments: attachments, delivery: delivery, model: model)
        case .turn(let turn):
            AssistantTurnView(
                blocks: turn.blocks, turn: nil, inProgress: turn.inProgress, liveCount: turn.liveCount,
                startedAt: turn.startedAt, endedAt: turn.inProgress ? nil : turn.endedAt ?? turn.startedAt ?? .distantPast,
                info: TurnInfo(startedAt: turn.startedAt, closedKind: turn.closed)
            )
        case .notice(_, let text, let isError):
            Label(text, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.footnote)
                .foregroundStyle(isError ? Palette.removed : Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// Older records load when the top of the timeline comes into view, as in a local conversation.
private struct RemoteLoadOlder: View {
    let model: RemoteSessionModel
    @Environment(\.timelineScroll) private var scroll
    @State private var inView = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: 36)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { inView = $0 > scroll.top }
            .task(id: "\(inView)-\(model.rows.first?.id ?? "")") {
                guard inView else { return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let anchor = model.rows.first?.id
                Task {
                    await model.loadOlder()
                    if let anchor { scroll.keep(anchor) }
                }
            }
            .accessibilityLabel("正在加载更早的消息")
    }
}

private struct RemoteUserBubble: View {
    let id: String
    let text: String
    let attachments: [RemoteAttachment]
    let delivery: RemotePendingMessage.Delivery?
    let model: RemoteSessionModel
    @Environment(\.conversationActions) private var actions

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let images = attachments.filter(\.isImage)
            if !images.isEmpty {
                HStack(spacing: 6) { ForEach(images) { RemoteImageThumb(attachment: $0) } }
            }
            ForEach(attachments.filter { !$0.isImage }) { attachment in
                Label(attachment.name, systemImage: "paperclip").font(.caption)
            }
            if !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .lineSpacing(3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .contextMenu {
                        Button { copyToPasteboard(text) } label: { Label("复制", systemImage: "doc.on.doc") }
                        Button { actions.present(.text(text)) } label: { Label("选择文本", systemImage: "selection.pin.in.out") }
                    }
            }
            // On its way: said in words, not by dimming the message (which read as a failure).
            if delivery == .sending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("发送中…").font(.caption2).foregroundStyle(Palette.faint)
                }
            }
            if case .uncertain(let message)? = delivery {
                HStack(spacing: 10) {
                    Text("不确定是否送达：\(message)").font(.caption).foregroundStyle(Palette.waiting)
                    Button("移除") { model.dismiss(pending: id) }.font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 60)
    }
}

/// A picture a message carries: fetched from the account's server, opened full screen on a tap.
private struct RemoteImageThumb: View {
    let attachment: RemoteAttachment
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?
    @State private var failed = false
    @State private var viewing = false

    var body: some View {
        Group {
            if let image {
                Button { viewing = true } label: {
                    Image(uiImage: image).resizable().scaledToFill()
                }
                .buttonStyle(.plain)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(Palette.faint)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 96, height: 96)
        .background(Palette.field)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(Text(attachment.name))
        .task(id: attachment.id) {
            if let data = attachment.data { image = UIImage(data: data); failed = image == nil; return }
            guard let link = attachment.link, let client = app.remote.client,
                  let data = try? await client.data(at: link), let loaded = UIImage(data: data) else { failed = true; return }
            image = loaded
        }
        .fullScreenCover(isPresented: $viewing) {
            if let image { ImageViewer(image: image, name: attachment.name) }
        }
    }
}

/// In the composer's place while nothing can be sent: why, and the one thing to do about it.
private struct RemoteBlockBar: View {
    let text: String
    var action: (title: LocalizedStringKey, perform: () -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.subheadline).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action.title) { Haptics.tap(); action.perform() }
                    .buttonStyle(.capsule(height: 36, fill: false))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 9)
        .frame(minHeight: 54)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

/// A note from the agent that asks for nothing; its own actions (dismiss…) are one tap away.
private struct RemoteNoticeLine: View {
    let notice: RemoteNotice
    let model: RemoteSessionModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.severity == "error" ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(notice.severity == "error" ? Palette.removed : Palette.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).foregroundStyle(Palette.ink)
                if let message = notice.message, !message.isEmpty { Text(message).foregroundStyle(Palette.secondary).lineLimit(3) }
            }
            Spacer(minLength: 0)
            if let action = notice.actions.first(where: { !$0.required }) {
                Button { Task { _ = await model.respond(notice, action: action.id) } } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary).hitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(RemoteNoticeText.title(of: action, in: notice)))
            }
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
