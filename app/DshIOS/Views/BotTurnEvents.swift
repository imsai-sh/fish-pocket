import SwiftUI

/// What a Bot did in a reply beyond its words, drawn where the reply is: who it messaged or
/// stopped, a Bot or group it made, what it remembered, a chart it showed, a question that
/// closed unanswered. The calls themselves stay in the folded steps like any tool call.
struct BotTurnEvents: View {
    @Environment(AppModel.self) private var app
    @Environment(\.botComposer) private var composer
    let blocks: [AssistantBlock]
    @State private var exchange: BotExchangePair?

    var body: some View {
        if case .bot(let botId)? = composer, let own = app.botTeam.bot(botId) {
            let closed = app.botTeam.team["closedCards"][own.sessionId]
            let calls = blocks.compactMap { block -> ToolCall? in
                guard case .tool(let call) = block, Self.drawn.contains(call.displayName) else { return nil }
                // A question shows here only once it closed unanswered on its card.
                if call.displayName == "ask_user" { return closed[call.id].isNull ? nil : call }
                return call.finished ? call : nil
            }
            if !calls.isEmpty {
                // One presenter for the whole reply, whichever line asked.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(calls) { call in event(call, own: own) }
                }
                .sheet(item: $exchange) { BotExchangeSheet(pair: $0) }
            }
        }
    }

    /// The calls a Bot ends a turn on: a card for the user, after what it said.
    static let cards: Set<String> = ["ask_user", "show_view", "request_secret", "request_connector", "mail_send"]

    /// The team's tools whose calls say something a reader wants in the reply itself.
    private static let drawn: Set<String> = [
        "message_bot", "stop_bot", "create_bot", "update_bot", "create_group", "update_group", "delete_group", "post_to_group",
        "read_group_chat", "remember", "forget", "show_view", "ask_user", "request_secret", "request_connector", "mail_send",
    ]

    private func find(_ nameOrId: String?) -> BotInfo? {
        guard let nameOrId, !nameOrId.isEmpty else { return nil }
        let team = app.botTeam
        return team.bot(nameOrId) ?? team.bots.first { $0.name.caseInsensitiveCompare(nameOrId) == .orderedSame }
    }

    @ViewBuilder
    private func event(_ call: ToolCall, own: BotInfo) -> some View {
        let team = app.botTeam
        let args = call.arguments
        let done = call.finished
        let failed = call.isError
        switch call.displayName {
        case "message_bot":
            let target = find(args["to"].string)
            let name = target?.name ?? args["to"].string ?? "…"
            if done && failed {
                BotEventLine(symbol: "exclamationmark.bubble", text: String(localized: "没能联系上\(name)"), tone: Palette.removed)
            } else {
                BotEventLine(symbol: "arrow.up.message", text: String(localized: "给\(name)发了消息"), bot: target) {
                    if let target { exchange = BotExchangePair(a: own.id, b: target.id) }
                }
            }
        case "stop_bot":
            let target = find(args["bot"].string)
            let name = target?.name ?? args["bot"].string ?? "…"
            if done && failed {
                BotEventLine(symbol: "exclamationmark.circle", text: String(localized: "没能让\(name)停下"), tone: Palette.removed)
            } else {
                BotEventLine(symbol: "stop.circle", text: String(localized: "让\(name)停下了"), bot: target) {
                    if let target { exchange = BotExchangePair(a: own.id, b: target.id) }
                }
            }
        case "create_bot":
            if done, !failed, let created = find(args["name"].string) {
                BotEventLine(symbol: "person.badge.plus", text: String(localized: "创建了\(created.name)"), bot: created) {
                    team.openRequest = BotOpenRequest(route: .bot(created.id), push: true)
                }
            }
        case "update_bot":
            if done, !failed, let target = find(args["name"].string) ?? find(args["bot"].string) ?? (args["bot"].isNull ? own : nil) {
                BotEventLine(symbol: "pencil.line", text: target.id == own.id ? String(localized: "更新了自己的资料") : String(localized: "更新了\(target.name)的资料"), bot: target)
            }
        case "create_group", "update_group", "delete_group", "post_to_group":
            if done { groupEvent(call) }
        case "read_group_chat":
            if done, !failed, let room = team.rooms.first(where: { $0.name == args["group"].string }) {
                BotEventLine(symbol: "text.bubble", text: String(localized: "看了「\(team.name(of: room))」的聊天记录")) {
                    team.openRequest = BotOpenRequest(route: .room(room.id), push: true)
                }
            }
        case "remember", "forget":
            if done { memoryEvent(call, own: own) }
        case "show_view":
            // A view that waits for an answer is the card above the composer; one that only
            // shows something stays here.
            if done, !failed, call.result?.hasPrefix("The view is on screen.") == true, !args["view"].isNull {
                BotShownView(title: args["title"].string ?? "", root: args["view"])
            }
        case "ask_user":
            if let outcome = team.team["closedCards"][own.sessionId][call.id].string {
                BotClosedQuestion(question: args, outcome: outcome)
            }
        case "request_secret":
            if done, !failed, let name = args["name"].string {
                BotEventLine(symbol: "key", text: String(localized: "向你要了密钥 \(name)"))
            }
        case "request_connector":
            if done, !failed {
                BotEventLine(symbol: "point.3.connected.trianglepath.dotted", text: String(localized: "请你连接一个服务"))
            }
        case "mail_send":
            if done, !failed {
                BotEventLine(symbol: "envelope", text: String(localized: "写了一封邮件"))
            }
        default:
            EmptyView()
        }
    }

    /// The group tools quote the group's name in their result; anything else is a refusal.
    @ViewBuilder
    private func groupEvent(_ call: ToolCall) -> some View {
        let team = app.botTeam
        let result = call.result ?? ""
        let name = result.firstMatch(of: #/^(?:Created group|Updated|Nothing changed in|Deleted|Posted in) "([^"]+)"/#).map { String($0.1) }
        if call.isError || name == nil {
            let text = switch call.displayName {
            case "create_group": String(localized: "没能创建群聊")
            case "update_group": String(localized: "没能修改群聊")
            case "delete_group": String(localized: "没能删除群聊")
            default: String(localized: "没能在群里发言")
            }
            BotEventLine(symbol: "exclamationmark.bubble", text: text, tone: Palette.removed)
        } else if let name {
            let room = call.displayName == "delete_group" ? nil : team.rooms.first { $0.name == name }
            let shown = room.map(team.name(of:)) ?? name
            let text = switch call.displayName {
            case "create_group": String(localized: "创建了群聊「\(shown)」")
            case "update_group": String(localized: "修改了群聊「\(shown)」")
            case "delete_group": String(localized: "删除了群聊「\(shown)」")
            default: String(localized: "在「\(shown)」里发了言")
            }
            BotEventLine(symbol: "person.2", text: text) {
                if let room { team.openRequest = BotOpenRequest(route: .room(room.id), push: true) }
            }
        }
    }

    @ViewBuilder
    private func memoryEvent(_ call: ToolCall, own: BotInfo) -> some View {
        let team = app.botTeam
        let result = call.result ?? ""
        let open = { team.memoryRequest = own.id }
        if call.isError {
            BotEventLine(symbol: "brain", text: call.displayName == "forget" ? String(localized: "没能从记忆里去掉") : String(localized: "没能记下来"), tone: Palette.removed)
        } else if result.hasPrefix("Already in ") {
            BotEventLine(symbol: "brain", text: String(localized: "已经记过了"), action: open)
        } else if ["Saved to ", "Updated in ", "Removed from "].contains(where: result.hasPrefix) {
            let scope = call.arguments["scope"].string?.trimmingCharacters(in: .whitespaces) ?? ""
            let teamWide = ["team", "团队", "共享"].contains(scope.lowercased())
            let text = teamWide ? String(localized: "更新了团队共享的记忆") : call.displayName == "forget" ? String(localized: "从记忆里去掉了一条") : String(localized: "记住了：\(call.arguments["text"].string ?? "")")
            BotEventLine(symbol: "brain", text: text, action: open)
        } else {
            BotEventLine(symbol: "brain", text: String(localized: "记忆没有变化"))
        }
    }
}

/// One line of what a Bot did, in the reply: a mark, a sentence, and somewhere to go when
/// there is more behind it.
struct BotEventLine: View {
    let symbol: String
    let text: String
    var bot: BotInfo?
    var tone: Color = Palette.secondary
    var action: (() -> Void)?

    var body: some View {
        let label = HStack(spacing: 8) {
            if let bot { BotAvatar(bot: bot, size: 20) } else { Image(systemName: symbol).font(.footnote).foregroundStyle(tone).frame(width: 20) }
            Text(text).font(.footnote).foregroundStyle(tone).lineLimit(2).multilineTextAlignment(.leading)
            if action != nil { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Palette.faint) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 34)
        .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        if let action {
            Button(action: action) { label }.buttonStyle(.plain)
        } else {
            label
        }
    }
}

/// A question card that closed without an answer on the card: it stays where it was asked.
private struct BotClosedQuestion: View {
    let question: JSON
    let outcome: String

    var body: some View {
        BotCard {
            Text(question["question"].string ?? "").font(.subheadline.weight(.semibold))
            if let detail = question["detail"].string, !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(Palette.secondary) }
            let options = question["options"].array.compactMap { $0["label"].string ?? $0.string }
            if !options.isEmpty {
                Text(options.joined(separator: " · ")).font(.footnote).foregroundStyle(Palette.faint)
            }
            Label(outcome == "replied" ? String(localized: "你用一条消息回答了") : String(localized: "没有回答"), systemImage: outcome == "replied" ? "text.bubble" : "xmark.circle")
                .font(.caption).foregroundStyle(Palette.secondary)
        }
        .opacity(0.8)
    }
}

// MARK: - Bot to Bot

struct BotExchangePair: Identifiable, Hashable {
    let a: String
    let b: String
    var id: String { a + "\u{1}" + b }
}

/// What two Bots said to each other: the requests, replies and reports that never show in
/// either one's chat with the user.
struct BotExchangeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let pair: BotExchangePair
    @State private var entries: [JSON] = []
    @State private var loaded = false
    /// Long messages read whole, by entry id.
    @State private var whole: [String: String] = [:]
    @State private var loadingWhole: Set<String> = []

    var body: some View {
        let team = app.botTeam
        let a = team.bot(pair.a), b = team.bot(pair.b)
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if loaded && entries.isEmpty {
                            Text("它们之间还没有说过话。").font(.footnote).foregroundStyle(Palette.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        ForEach(entries, id: \.["id"]) { entry in row(entry) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(20)
                    .modifier(LinkOpening())
                }
                .onChange(of: entries.count) { _, _ in proxy.scrollTo("end") }
            }
            .background(Palette.background)
            .navigationTitle([a?.name, b?.name].compactMap { $0 }.joined(separator: " ⇄ "))
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
        }
        // New messages land while the page is open: each team revision reads again.
        .task(id: team.team["revision"].double) {
            if let value = try? await team.call("exchange", ["a": .string(pair.a), "b": .string(pair.b)]) {
                entries = value.array.sorted { ($0["time"].double ?? 0) < ($1["time"].double ?? 0) }
            }
            loaded = true
        }
    }

    @ViewBuilder
    private func row(_ entry: JSON) -> some View {
        let team = app.botTeam
        let from = entry["from"].string.flatMap(team.bot)
        let id = entry["id"].string ?? ""
        let long = !entry["length"].isNull
        HStack(alignment: .top, spacing: 10) {
            BotAvatar(bot: from, name: from?.name ?? String(localized: "你"), size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(from?.name ?? String(localized: "你")).font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                    Text(Self.role(entry["role"].string)).font(.caption2).foregroundStyle(Palette.faint)
                    if let time = entry["time"].double {
                        Text(Date(timeIntervalSince1970: time / 1000), format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(Palette.faint)
                    }
                }
                MarkdownView(text: whole[id] ?? BotEarlierParts.withoutLongNote(entry["text"].string ?? ""))
                if long, whole[id] == nil {
                    Button {
                        loadingWhole.insert(id)
                        Task {
                            if let value = try? await team.call("exchange-text", ["id": .string(id)]), let text = value["text"].string {
                                whole[id] = value["whole"].bool == false ? text + "\n\n…" : text
                            } else {
                                app.showToast(String(localized: "这条消息读不出完整内容"), tone: .warning)
                            }
                            loadingWhole.remove(id)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if loadingWhole.contains(id) { ProgressView().controlSize(.mini) }
                            Text("展开全部（\(entry["length"].int ?? 0) 字）")
                        }
                        .font(.footnote)
                    }
                    .disabled(loadingWhole.contains(id))
                }
            }
        }
        .contextMenu {
            Button { copyToPasteboard(whole[id] ?? entry["text"].string ?? "") } label: { Label("复制", systemImage: "doc.on.doc") }
        }
    }

    private static func role(_ role: String?) -> String {
        switch role {
        case "request": String(localized: "交代")
        case "reply": String(localized: "回复")
        case "report": String(localized: "汇报")
        case "stopped": String(localized: "叫停")
        default: ""
        }
    }
}
