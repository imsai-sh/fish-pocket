import Observation
import SwiftUI

/// One entry of a Bot's own chat, as ds-bot's `chat` endpoint and feed give it:
/// `{kind: user|bot|answer|event|view|closed|divider, text?, time, seq?}`.
struct BotChatItem: Identifiable, Hashable {
    let json: JSON
    let id: String

    init(_ json: JSON, index: Int) {
        self.json = json
        let seq = json["seq"].int.map(String.init) ?? "t\(json["time"].int ?? index)"
        id = "\(seq)-\(json["kind"].string ?? "")-\(abs((json["text"].string ?? "").hashValue % 100_000))"
    }

    var kind: String { json["kind"].string ?? "" }
    var text: String { json["text"].string ?? "" }
}

/// A Bot's own chat: newest page first, earlier pages on demand, new entries from the feed.
@MainActor
@Observable
final class BotChatModel {
    let botId: String
    private(set) var items: [BotChatItem] = []
    private(set) var cursor: JSON = .null
    private(set) var loaded = false
    private(set) var loadingEarlier = false
    private(set) var error: String?
    @ObservationIgnored private weak var team: BotModel?
    @ObservationIgnored private var listener: UUID?

    init(botId: String) {
        self.botId = botId
    }

    func attach(_ team: BotModel) {
        guard self.team == nil else { return }
        self.team = team
        listener = team.addListener { [weak self] sessionId, item in
            guard let self, let team = self.team, team.bot(self.botId)?.sessionId == sessionId else { return }
            self.append(item)
        }
    }

    func detach() {
        if let listener { team?.removeListener(listener) }
        listener = nil
    }

    func load() async {
        guard let team else { return }
        do {
            let page = try await team.call("chat", ["botId": .string(botId)])
            items = page["items"].array.enumerated().map { BotChatItem($1, index: $0) }
            cursor = page["cursor"]
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    func loadEarlier() async {
        guard let team, !cursor.isNull, !loadingEarlier else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        guard let page = try? await team.call("chat", ["botId": .string(botId), "cursor": cursor]) else { return }
        let earlier = page["items"].array.enumerated().map { BotChatItem($1, index: -1000 - $0) }
        items = earlier.filter { item in !items.contains { $0.id == item.id } } + items
        cursor = page["cursor"]
    }

    private func append(_ json: JSON) {
        let item = BotChatItem(json, index: items.count)
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
    }
}

/// A Bot's own chat, drawn natively.
struct BotChatView: View {
    @Environment(AppModel.self) private var app
    let botId: String
    @State private var model: BotChatModel
    @State private var draft = ""
    @State private var sending = false
    @State private var detailOpen = false
    @FocusState private var focused: Bool

    init(botId: String) {
        self.botId = botId
        _model = State(initialValue: BotChatModel(botId: botId))
    }

    var body: some View {
        let team = app.botTeam
        Group {
            if let bot = team.bot(botId) {
                content(bot)
            } else {
                ContentUnavailableView("这个 Bot 已不在团队里", systemImage: "person.slash")
            }
        }
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.attach(team)
            await model.load()
        }
        .task(id: team.feedGeneration) { if model.loaded { await model.load() } }
        .onDisappear { model.detach() }
        .sheet(isPresented: $detailOpen) { BotDetailView(botId: botId) }
    }

    @ViewBuilder
    private func content(_ bot: BotInfo) -> some View {
        let team = app.botTeam
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !model.cursor.isNull {
                        Button { Task { await model.loadEarlier() } } label: {
                            if model.loadingEarlier { ProgressView() } else { Text("加载更早的消息").font(.footnote) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: .infinity)
                    }
                    if model.loaded && model.items.isEmpty && !bot.waiting {
                        Text("还没有消息").font(.footnote).foregroundStyle(Palette.faint).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(model.items) { item in BotChatRow(item: item, bot: bot) }
                    if let text = team.writing[bot.sessionId], !text.isEmpty {
                        BotSays(bot: bot) { MarkdownView(text: text, cached: false) }
                    } else if team.isWorking(bot.id) {
                        HStack(spacing: 6) {
                            StatusDot(state: .running, size: 6)
                            Text("正在干活…").font(.footnote).foregroundStyle(Palette.running)
                        }
                        .padding(.leading, 38)
                    }
                    pending(bot)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
                .readableWidth()
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.items.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: team.writing[bot.sessionId]) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { composer(bot) }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { detailOpen = true } label: {
                    HStack(spacing: 8) {
                        BotAvatar(name: bot.name, color: team.color(of: bot), size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(bot.name).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                            if team.isWorking(bot.id) {
                                Text("在干活").font(.caption2).foregroundStyle(Palette.running)
                            } else if !bot.role.isEmpty {
                                Text(bot.role).font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看 Bot 详情")
            }
            if team.isWorking(bot.id) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await team.stop(bot) } } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("停止")
                }
            }
        }
        .onAppear { app.clearUnread(bot.sessionId) }
        .onDisappear { app.clearUnread(bot.sessionId) }
    }

    /// What waits on the user: a model to pick, a question, a tool approval, a form.
    @ViewBuilder
    private func pending(_ bot: BotInfo) -> some View {
        let team = app.botTeam
        if bot.waiting {
            BotModelPicker(bot: bot)
        }
        if let question = team.question(of: bot) {
            BotQuestionCard(bot: bot, question: question)
        }
        ForEach(app.approvals[bot.sessionId] ?? []) { approval in
            BotCard {
                Text("\(bot.name)想要使用「\(approval.toolName)」").font(.subheadline.weight(.semibold))
                if let reason = approval.reason { Text(reason).font(.footnote).foregroundStyle(Palette.secondary) }
                HStack(spacing: 8) {
                    Button("允许") { Task { await app.answerApproval(approval, session: bot.sessionId, allow: true) } }
                        .buttonStyle(.capsule(height: 36, fill: false))
                    Button("拒绝") { Task { await app.answerApproval(approval, session: bot.sessionId, allow: false) } }
                        .buttonStyle(.capsule(.outline, height: 36, fill: false))
                }
            }
        }
        if let view = team.pendingView(of: bot) {
            BotCard {
                Text(view["view"]["title"].string ?? view["title"].string ?? String(localized: "\(bot.name)发来一张表单")).font(.subheadline.weight(.semibold))
                Text("这类表单暂时要在网页版里填写。").font(.footnote).foregroundStyle(Palette.secondary)
                Button("打开网页版") { app.webRequest = UUID() }.buttonStyle(.capsule(.outline, height: 36, fill: false))
            }
        }
    }

    private func composer(_ bot: BotInfo) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发消息给\(bot.name)", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.vertical, 8)
            Button(action: { send(bot) }) {
                Image(systemName: "arrow.up").font(.subheadline.weight(.bold)).foregroundStyle(Palette.onInk)
                    .frame(width: 36, height: 36).background(canSend(bot) ? Palette.ink : Palette.faint, in: Circle())
            }
            .disabled(!canSend(bot))
            .accessibilityLabel("发送")
        }
        .padding(.leading, 18)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 4)
        .background(Palette.background)
        .readableWidth()
    }

    private func canSend(_ bot: BotInfo) -> Bool {
        !sending && !bot.waiting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ bot: BotInfo) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend(bot) else { return }
        sending = true
        Haptics.tap()
        Task {
            if await app.botTeam.send(text, to: bot) {
                draft = ""
                clearFocusedTextInput()
            }
            sending = false
        }
    }
}

/// One entry of the chat.
private struct BotChatRow: View {
    @Environment(AppModel.self) private var app
    let item: BotChatItem
    let bot: BotInfo

    var body: some View {
        switch item.kind {
        case "user":
            Text(item.text)
                .font(.callout)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
                .textSelection(.enabled)
        case "bot":
            BotSays(bot: bot) { MarkdownView(text: item.text) }
        case "answer":
            note(answerText)
        case "event":
            note(eventText)
        case "view", "closed":
            BotCard {
                Text(item.json["title"].string ?? item.json["question"]["question"].string ?? String(localized: "\(bot.name)发来一张卡片"))
                    .font(.subheadline.weight(.semibold))
                Text(item.kind == "closed" ? String(localized: "已处理") : String(localized: "完整内容请在网页版查看"))
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
            .padding(.leading, 38)
        case "divider":
            HStack(spacing: 8) {
                Rectangle().fill(Palette.stroke).frame(height: 1)
                Text("新的一段对话").font(.caption2).foregroundStyle(Palette.faint).fixedSize()
                Rectangle().fill(Palette.stroke).frame(height: 1)
            }
        default:
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity)
    }

    private var answerText: String {
        let picked = item.json["answers"].array.flatMap { $0["selected"].array.compactMap(\.string) + [$0["custom"].string].compactMap { $0 } }
        if !picked.isEmpty { return String(localized: "你回答了：\(picked.joined(separator: "、"))") }
        return item.text.isEmpty ? String(localized: "你回答了") : item.text
    }

    private var eventText: String {
        let name = item.json["name"].string ?? String(localized: "其他 Bot")
        switch item.json["role"].string {
        case "request": return String(localized: "\(name)交来一件事")
        case "reply": return String(localized: "\(name)回复了")
        case "report": return String(localized: "\(name)汇报了进展")
        case "stopped": return String(localized: "\(name)的工作已停止")
        default: return name
        }
    }
}

/// The Bot's mark beside what it says.
struct BotSays<Content: View>: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BotAvatar(name: bot.name, color: app.botTeam.color(of: bot), size: 28)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A rounded card in the chat.
struct BotCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A question the Bot asked (`ask_user`): its options as buttons.
private struct BotQuestionCard: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo
    let question: JSON
    @State private var picked: Set<String> = []
    @State private var sending = false

    var body: some View {
        let multi = question["multiSelect"].bool ?? false
        BotCard {
            Text(question["question"].string ?? "").font(.subheadline.weight(.semibold))
            if let detail = question["detail"].string, !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(Palette.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(question["options"].array.compactMap { $0["label"].string ?? $0.string }, id: \.self) { label in
                    Button {
                        if multi {
                            if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
                            Haptics.select()
                        } else {
                            answer([label])
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if multi { Image(systemName: picked.contains(label) ? "checkmark.square.fill" : "square") }
                            Text(label).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(Palette.background, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.stroke))
                    }
                    .buttonStyle(.plain)
                    .disabled(sending)
                }
            }
            HStack(spacing: 8) {
                if multi {
                    Button("提交") { answer(Array(picked)) }
                        .buttonStyle(.capsule(height: 36, fill: false))
                        .disabled(picked.isEmpty || sending)
                }
                Button("先不回答") { Task { await app.botTeam.dismiss(question, of: bot) } }
                    .buttonStyle(.capsule(.outline, height: 36, fill: false))
            }
        }
    }

    private func answer(_ selected: [String]) {
        sending = true
        Haptics.tap()
        Task {
            _ = await app.botTeam.answer(question, of: bot, selected: selected)
            sending = false
        }
    }
}

/// A Bot holds its greeting until it has a model.
private struct BotModelPicker: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo
    @State private var saving = false

    var body: some View {
        let models = app.botTeam.team["models"].array
        BotCard {
            Text("\(bot.name)还没有模型，选一个它就会开口").font(.subheadline.weight(.semibold))
            if models.isEmpty {
                Text("还没有可用的模型。先在「设置 › 账号与余额」登录 DeepSeek 或填入 API Key。").font(.footnote).foregroundStyle(Palette.secondary)
            }
            ForEach(models.compactMap { model in model["ref"].string.map { ($0, model["name"].string ?? $0) } }, id: \.0) { ref, name in
                Button {
                    saving = true
                    Haptics.tap()
                    Task {
                        if await app.perform({ try await app.botTeam.call("update-bot", ["id": .string(bot.id), "model": .string(ref)]) }) {
                            await app.botTeam.refreshState()
                        }
                        saving = false
                    }
                } label: {
                    HStack {
                        Text(name)
                        Spacer()
                        if ref == app.botTeam.team["defaultModel"].string { Text("默认").font(.caption).foregroundStyle(Palette.secondary) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(Palette.background, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.stroke))
                }
                .buttonStyle(.plain)
                .disabled(saving)
            }
        }
    }
}
