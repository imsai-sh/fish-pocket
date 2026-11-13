import SwiftUI

/// What a Bot's chat or a group chat changes in `ConversationView`: the title in the bar
/// and cards above the composer. Everything else (attachments, approvals, stopping,
/// the keyboard) is the conversation view's own: a Bot's chat is an ordinary session.
struct BotChrome {
    var title: AnyView
    var accessory: AnyView?
    /// The chat's own menu in the bar, given the conversation it is for and how to reach its tools.
    var menu: ((SessionModel, BotChatTools?) -> AnyView)?
    /// The chat has the conversation's tools: the workbench, the browser and the background jobs
    /// floating over its foot. A Bot's own chat does; a group's session only relays its members' replies.
    var tools = false
}

/// What a Bot's chat menu opens of the conversation's tools.
struct BotChatTools {
    /// Shows or hides the workbench, where the tab last looked at is.
    let toggleWorkbench: () -> Void
    /// The browser alone, full screen.
    let openBrowser: () -> Void
}

/// How a Bot's timeline differs: turns that answered another Bot stay out (ds-bot's own
/// window draws none of them), and a group's rounds are drawn as its members' posts.
struct BotTimeline: Equatable {
    var hiddenTurns: Set<Int> = []
    var room = false
    /// The current part, when the chat has earlier ones: they are read with `earlier` from it.
    var earlierFrom: String?
    /// Reasoning is drawn (ds-bot's `thinking` preference); off, a reply shows its steps without it.
    var showsThinking = false
    /// The session these replies belong to, for what is kept per reply (a reaction).
    var sessionId = ""

    func hides(_ block: AssistantBlock) -> Bool {
        if case .reasoning = block { return !showsThinking }
        return false
    }

    /// The Bot's fixed reply to the handoff package of a new part (ds-bot's constants.js).
    static let handoffReply = "Noted. I have my handoff note and carry on from here."

    /// The handoff package and its fixed reply are the plugin's bookkeeping, not the conversation.
    func hides(_ item: TimelineItem) -> Bool {
        switch item {
        case .trigger(let trigger): return trigger.handoff
        case .assistant(let turn, let blocks, _, _):
            if hiddenTurns.contains(turn) { return true }
            let texts = blocks.compactMap { if case .text(_, let text) = $0 { text } else { nil } }
            return texts.count == 1 && texts[0].trimmingCharacters(in: .whitespacesAndNewlines) == Self.handoffReply
        default: return false
        }
    }
}

private struct BotTimelineKey: EnvironmentKey {
    static let defaultValue: BotTimeline? = nil
}

extension EnvironmentValues {
    var botTimeline: BotTimeline? {
        get { self[BotTimelineKey.self] }
        set { self[BotTimelineKey.self] = newValue }
    }
    var botComposer: BotComposer? {
        get { self[BotComposerKey.self] }
        set { self[BotComposerKey.self] = newValue }
    }
}

/// Whose settings the composer's ＋ tray shows in a Bot page: the Bot's own (its model,
/// thinking level and permission, which all its chats run on), or none for a group, whose
/// members each answer on their own.
enum BotComposer: Equatable {
    case bot(String)
    case room(String)

    /// DSH commands that set this session's model, modes, goal or context: a Bot keeps its own.
    static let hiddenCommands: Set<String> = ["model", "goal", "plan", "compact", "permission"]
}

private struct BotComposerKey: EnvironmentKey {
    static let defaultValue: BotComposer? = nil
}

/// One round of a group chat. The group's own Session runs no model of its own words: each
/// user message gets one `group_relay` call whose result lists the members' replies,
/// `{"replies":[{botId, name, text, time, kind?}]}` (ds-bot's shared/group-replies.js).
struct RoomRelay: Hashable {
    let call: ToolCall
    var replies: [JSON] { call.result.map(Self.replies(in:)) ?? [] }
    var settled: Bool { call.result != nil }
    /// The settled result is not whole JSON: compaction pruned its middle, and some replies may be gone.
    var broken: Bool { call.result.map { (try? JSONDecoder().decode(JSON.self, from: Data($0.utf8))) == nil } ?? false }
    /// A settled round nobody spoke in (a notice the group took in): there is nothing to draw.
    var empty: Bool { settled && !broken && replies.isEmpty }

    init?(blocks: [AssistantBlock]) {
        for block in blocks {
            if case .tool(let call) = block, call.displayName == "group_relay" { self.call = call; return }
        }
        return nil
    }

    /// The replies of a settled result; one whose middle compaction pruned still gives the
    /// complete reply objects that survived.
    static func replies(in text: String) -> [JSON] {
        if let value = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)) { return value["replies"].array }
        guard let head = text.range(of: #""replies"\s*:\s*\["#, options: .regularExpression) else { return [] }
        var found: [JSON] = []
        var depth = 0, start: String.Index?, inString = false, escaped = false
        var index = head.upperBound
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0, let from = start {
                    if let value = try? JSONDecoder().decode(JSON.self, from: Data(text[from...index].utf8)) { found.append(value) }
                    start = nil
                }
            } else if ch == "]" && depth == 0 {
                break
            }
            index = text.index(after: index)
        }
        return found
    }
}

/// A group chat: the group's own session in the conversation view.
struct BotRoomView: View {
    @Environment(AppModel.self) private var app
    let roomId: String
    /// See `BotChatView.selection`.
    @State private var selection: String?
    @State private var detailOpen = false

    var body: some View {
        let team = app.botTeam
        if let room = team.room(roomId) {
            ConversationView(sessionId: room.sessionId, selection: $selection, openDrawer: nil, bot: BotChrome(
                title: AnyView(Button { detailOpen = true } label: {
                    HStack(spacing: 8) {
                        RoomAvatar(room: room, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(team.name(of: room)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                            Text("\(room.members.count) 个 Bot").font(.caption2).foregroundStyle(Palette.secondary)
                        }
                    }
                    .modifier(BotTitleCapsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看群聊设置")),
                accessory: AnyView(RoomMentions(room: room)),
                menu: { model, _ in AnyView(BotChatMenu(target: .room(room.id), model: model)) }
            ))
            .environment(\.botTimeline, BotTimeline(room: true, earlierFrom: room.json["ownParts"].array.isEmpty ? nil : room.sessionId, showsThinking: team.showsThinking, sessionId: room.sessionId))
            .environment(\.botComposer, .room(room.id))
            // The round's replies as each member speaks.
            .task(id: room.id) { await team.followRounds(of: room.id) }
            .openingOtherSessions($selection, from: room.sessionId)
            .sheet(isPresented: $detailOpen) {
                RoomDetailView(roomId: roomId).environment(\.browserLinks, BrowserLinks(sessionId: room.sessionId, origin: app.client.origin))
            }
            .onChange(of: team.scheduleRequest) { _, request in
                guard request == .room(roomId) else { return }
                team.scheduleRequest = nil
                Task { try? await Task.sleep(for: .milliseconds(350)); detailOpen = true }
            }
            .onAppear { app.clearUnread(room.sessionId); team.visibleChat = room.id }
            .onDisappear { app.clearUnread(room.sessionId); if team.visibleChat == room.id { team.visibleChat = nil } }
        } else if team.status == .unknown {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
        } else {
            ContentUnavailableView("这个群聊已经不在了", systemImage: "person.2.slash")
        }
    }
}

/// Above a group's composer: who speaks now, and a tap to @ a member.
private struct RoomMentions: View {
    @Environment(AppModel.self) private var app
    @Environment(\.sessionModel) private var session
    let room: RoomInfo

    var body: some View {
        let team = app.botTeam
        let members = room.members.compactMap(team.bot)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(team.approvals(inRoom: room.id), id: \.["id"]) { approval in RoomApprovalCard(approval: approval) }
            if let goal = room.json["goal"].nonNull, goal["status"].string != "complete", goal["status"].string != "stopped" {
                Button { team.scheduleRequest = .room(room.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "flag").font(.caption)
                        Text(goal["title"].string ?? goal["brief"].string ?? "").lineLimit(1)
                        if let index = goal["current"].int, index >= 0, !goal["stages"].array.isEmpty {
                            Text("\(min(index + 1, goal["stages"].array.count))/\(goal["stages"].array.count)").monospacedDigit()
                        }
                        Text(RoomGoalSection.status(goal)).foregroundStyle(Palette.secondary)
                        Spacer(minLength: 0)
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14).frame(minHeight: 34)
                    .background(Palette.grouped, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(members) { member in
                        Button {
                            Haptics.select()
                            guard let composer = session?.composer else { return }
                            let prefix = composer.text.isEmpty || composer.text.hasSuffix(" ") ? "" : " "
                            composer.text += "\(prefix)@\(member.name) "
                        } label: {
                            Text("@\(member.name)").font(.footnote).foregroundStyle(Palette.ink)
                                .padding(.horizontal, 12).frame(minHeight: 30)
                                .background(Palette.field, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// A member waits for the user to allow a tool in the group (only answerable here).
private struct RoomApprovalCard: View {
    @Environment(AppModel.self) private var app
    let approval: JSON
    @State private var sending = false

    var body: some View {
        let team = app.botTeam
        let name = approval["botId"].string.flatMap(team.bot)?.name ?? ""
        BotCard {
            Text("\(name)想要使用「\(approval["tool"].string ?? "")」").font(.subheadline.weight(.semibold))
            if let reason = approval["reason"].string, !reason.isEmpty {
                Text(reason).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(4)
            }
            if let detail = approval["detail"]["code"].string ?? approval["detail"]["text"].string, !detail.isEmpty {
                Text(detail).font(.caption.monospaced()).foregroundStyle(Palette.ink).lineLimit(6)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 8) {
                Button("允许一次") { answer(true) }.buttonStyle(.capsule(height: 36, fill: false))
                Button("拒绝") { answer(false) }.buttonStyle(.capsule(.outline, height: 36, fill: false))
            }
            .disabled(sending)
        }
    }

    private func answer(_ allow: Bool) {
        sending = true
        Task { await app.botTeam.answerApproval(approval, allow: allow); sending = false }
    }
}

extension View {
    /// A Bot page's conversation picked another session (from its reminders): that one opens
    /// as an ordinary conversation, leaving the Bot pages.
    func openingOtherSessions(_ selection: Binding<String?>, from sessionId: String) -> some View {
        modifier(OpenOtherSession(selection: selection, sessionId: sessionId))
    }
}

private struct OpenOtherSession: ViewModifier {
    @Environment(AppModel.self) private var app
    @Binding var selection: String?
    let sessionId: String

    func body(content: Content) -> some View {
        content.onChange(of: selection) { _, id in
            guard let id, id != sessionId else { return }
            selection = nil
            app.open(session: id)
        }
    }
}
