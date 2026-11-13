import SwiftUI

/// A group round: what each member said, under its name and mark, with the lines in
/// between that say what else happened (someone stopped, did not answer, waits for the user).
struct RoomRelayView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.botTimeline) private var timeline
    let relay: RoomRelay
    let running: Bool

    /// A member's messages in a row read as one block under its name.
    private struct Block: Identifiable {
        let id: Int
        let reply: JSON
        var texts: [String]
    }

    private static func stack(_ replies: [JSON]) -> [Block] {
        var blocks: [Block] = []
        for (index, reply) in replies.enumerated() {
            let plain = reply["kind"].isNull
            let text = reply["text"].string ?? ""
            if plain, let last = blocks.last, last.reply["kind"].isNull, last.reply["botId"] == reply["botId"] {
                blocks[blocks.count - 1].texts.append(text)
            } else {
                blocks.append(Block(id: index, reply: reply, texts: plain ? (reply["texts"].array.compactMap(\.string).isEmpty ? [text] : reply["texts"].array.compactMap(\.string)) : []))
            }
        }
        return blocks
    }

    var body: some View {
        let team = app.botTeam
        // Until the round settles its replies come from its progress, one as each member speaks.
        let live = relay.settled ? nil : team.round(relay.call.id)
        let replies = live?["replies"].array ?? relay.replies
        let speaking = (live?["speaking"].array ?? []).compactMap { $0.string.flatMap(team.bot) }
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Self.stack(replies)) { block in
                let reply = block.reply
                let bot = reply["botId"].string.flatMap(team.bot)
                switch reply["kind"].string {
                case nil:
                    RoomMessage(bot: bot, name: bot?.name ?? reply["name"].string ?? "?", texts: block.texts,
                                reactionKey: timeline.map { BotReactions.key(session: $0.sessionId, call: relay.call.id, index: block.id) })
                        .transition(.asymmetric(insertion: .offset(y: 14).combined(with: .opacity), removal: .identity))
                case "user":
                    // What the user added while the round ran.
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(reply["text"].string ?? "").font(.callout)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        if let via = reply["via"].string {
                            Label("来自\(IMPlatform.name(via))", systemImage: "arrow.down.left.circle").font(.caption2).foregroundStyle(Palette.faint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, 60)
                default:
                    if let line = Self.event(reply, name: bot?.name ?? reply["name"].string ?? String(localized: "有个 Bot")) {
                        RoomEventLine(symbol: line.symbol, text: line.text, tone: line.failed ? Palette.removed : Palette.secondary, bot: bot)
                    }
                }
            }
            if relay.broken && replies.isEmpty {
                Text("这一轮的回复显示不出来").font(.footnote).foregroundStyle(Palette.secondary)
            }
            if running && !relay.settled {
                if speaking.isEmpty {
                    BotShimmer(text: String(localized: "成员正在发言…")).frame(minHeight: 28)
                }
                ForEach(speaking) { member in BotSpeakingLine(bot: member).transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // While the round runs, a reply rises in where its member was typing.
        .animation(live == nil ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: replies.count)
        .animation(live == nil ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: speaking.map(\.id))
    }

    /// What a reply that is not a message says (ds-bot's group round kinds).
    private static func event(_ reply: JSON, name: String) -> (symbol: String, text: String, failed: Bool)? {
        switch reply["kind"].string {
        case "failed":
            return ("exclamationmark.triangle", String(localized: "\(name)停下了：\(failure(code: reply["code"].string, text: reply["text"].string))。给它换个模型，或者让它继续。"), true)
        case "lookup":
            let text = reply["text"].string ?? ""
            return ("magnifyingglass", text.isEmpty ? String(localized: "\(name)翻了翻自己的聊天记录") : String(localized: "\(name)在自己的聊天记录里查了「\(text)」"), false)
        case "missed":
            return ("clock.badge.exclamationmark", String(localized: "\(name)没有及时回复"), false)
        case "admin-passed":
            return ("person.crop.circle.badge.questionmark", String(localized: "\(name)没有回答，也没有点名别人。用 @名字 直接叫某个成员"), false)
        case "paused":
            let names = ([name] + reply["names"].array.compactMap(\.string)).joined(separator: String(localized: "、"))
            return ("pause.circle", reply["idle"].bool == true
                    ? String(localized: "\(names)来回说了 \(reply["count"].int ?? 0) 轮没有进展，先停下了。在这里说句话让它们继续")
                    : String(localized: "Bot 之间接力了 \(reply["count"].int ?? 0) 次，先停下了"), false)
        case "resumed": return ("arrow.clockwise", String(localized: "\(name)的工作被重启打断，已经接着做了"), false)
        case "cut": return ("xmark.circle", String(localized: "\(name)的工作又被重启打断，停下了"), false)
        case "approval": return ("hand.raised", String(localized: "\(name)停下来等你批准"), false)
        case "working": return ("play.circle", String(localized: "\(name)开始做了"), false)
        case "folder": return ("folder", reply["text"].string ?? "", false)
        case "stopped": return ("stop.circle", String(localized: "你让\(name)停下了"), false)
        case "done": return ("checkmark.circle", String(localized: "\(name)做完了"), false)
        case "goal": return ("flag", reply["text"].string ?? String(localized: "群目标有了进展"), false)
        default: return nil
        }
    }

    /// Why a member's turn failed, for the codes a person can do something about.
    static func failure(code: String?, text: String?) -> String {
        switch code {
        case "MISSING_CREDENTIAL", "INVALID_CREDENTIAL", "AUTH": String(localized: "模型的 API Key 缺失或无效")
        case "QUOTA", "ACCOUNT_QUOTA": String(localized: "模型的额度用完了")
        case "ACCOUNT_SIGN_IN_REQUIRED", "ACCOUNT_SIGNED_OUT", "ACCOUNT_TOKEN_INVALID": String(localized: "DeepSeek 账号需要重新登录")
        case "RATE_LIMIT", "RATE_LIMITED": String(localized: "请求太频繁")
        case "NETWORK", "TIMEOUT": String(localized: "网络不通")
        default: text.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) } ?? String(localized: "运行出错了（\(code ?? "?")）")
        }
    }
}

/// A line of a group round that is not a message.
struct RoomEventLine: View {
    let symbol: String
    let text: String
    var tone: Color = Palette.secondary
    var bot: BotInfo?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.footnote).foregroundStyle(tone).frame(width: 18)
            Text(text).font(.footnote).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 2)
    }
}

/// One member's message in a group: its mark opens its own chat; a long press has the same
/// actions a reply has in a Bot's own chat.
struct RoomMessage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.conversationActions) private var actions
    let bot: BotInfo?
    let name: String
    let texts: [String]
    var reactionKey: String?
    /// A post that came as a file with only its start: the file and the whole length.
    var file: JSON?
    var length: Int?
    @State private var whole: String?
    @State private var loading = false

    private var text: String { whole ?? texts.map(BotEarlierParts.withoutLongNote).joined(separator: "\n\n") }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                guard let bot else { return }
                Haptics.tap()
                app.botTeam.openRequest = BotOpenRequest(route: .bot(bot.id), push: true)
            } label: { BotAvatar(bot: bot, name: name, size: 28) }
                .buttonStyle(.plain)
                .disabled(bot == nil)
                .accessibilityLabel("打开\(name)的私聊")
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                if let whole {
                    MarkdownView(text: whole)
                } else {
                    ForEach(Array(texts.enumerated()), id: \.offset) { _, text in MarkdownView(text: BotEarlierParts.withoutLongNote(text)) }
                }
                if let file, whole == nil {
                    Button {
                        loading = true
                        Task {
                            if let value = try? await app.botTeam.call("file-text", ["file": file]), let read = value["text"].string {
                                whole = value["whole"].bool == false ? read + "\n\n…" : read
                            } else {
                                app.showToast(String(localized: "这条消息读不出完整内容"), tone: .warning)
                            }
                            loading = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if loading { ProgressView().controlSize(.mini) }
                            Text(length.map { String(localized: "展开全部（\($0) 字）") } ?? String(localized: "展开全部"))
                        }
                        .font(.footnote)
                    }
                    .disabled(loading)
                }
                if let reactionKey { BotReactionChip(key: reactionKey) }
            }
        }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            if let reactionKey { BotReactionMenu(key: reactionKey) }
            Button { copyToPasteboard(text) } label: { Label("复制", systemImage: "doc.on.doc") }
            Button { actions.present(.text(text)) } label: { Label("选择文本", systemImage: "selection.pin.in.out") }
            Button { actions.quote(text) } label: { Label("引用回复", systemImage: "arrowshape.turn.up.left") }
            ShareLink(item: text) { Label("分享", systemImage: "square.and.arrow.up") }
            ShareLink(item: MarkdownFile(name: name, text: text), preview: SharePreview(name)) { Label("存为 Markdown 文件", systemImage: "arrow.down.doc") }
            Button { ReadAloud.shared.toggle(text) } label: {
                ReadAloud.shared.speaking ? Label("停止朗读", systemImage: "speaker.slash") : Label("朗读", systemImage: "speaker.wave.2")
            }
            if let bot {
                Button { app.botTeam.openRequest = BotOpenRequest(route: .bot(bot.id), push: true) } label: { Label("打开\(bot.name)的私聊", systemImage: "bubble.left") }
            }
        }
    }
}

/// A Bot's post into the group from outside a round (it was asked to post, or reports back).
struct RoomPostView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.botTimeline) private var timeline
    let trigger: TurnTrigger

    var body: some View {
        let bot = trigger.senderId.flatMap(app.botTeam.bot)
        RoomMessage(bot: bot, name: bot?.name ?? trigger.senderName ?? String(localized: "有个 Bot"),
                    texts: [Self.withoutHeader(trigger.body)],
                    reactionKey: timeline.map { BotReactions.key(session: $0.sessionId, call: "post", index: trigger.seq) },
                    file: trigger.file, length: trigger.length)
    }

    /// A delivered message starts with a bracketed line saying who it is from.
    static func withoutHeader(_ text: String) -> String {
        guard text.hasPrefix("["), let match = text.firstMatch(of: #/^\[(Message from|Reply from|Group chat|Group post from|Bot team setup|Handoff · part|Secret card)[^\r\n]*\]\r?\n/#) else { return text }
        return String(text[match.range.upperBound...])
    }
}
