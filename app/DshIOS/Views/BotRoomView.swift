import SwiftUI

/// What a Bot's chat or a group chat changes in `ConversationView`: the title in the bar
/// and cards above the composer. Everything else (attachments, approvals, stopping,
/// the keyboard) is the conversation view's own: a Bot's chat is an ordinary session.
struct BotChrome {
    var title: AnyView
    var accessory: AnyView?
}

/// How a Bot's timeline differs: turns that answered another Bot stay out (ds-bot's own
/// window draws none of them), and a group's rounds are drawn as its members' posts.
struct BotTimeline: Equatable {
    var hiddenTurns: Set<Int> = []
    var room = false
}

private struct BotTimelineKey: EnvironmentKey {
    static let defaultValue: BotTimeline? = nil
}

extension EnvironmentValues {
    var botTimeline: BotTimeline? {
        get { self[BotTimelineKey.self] }
        set { self[BotTimelineKey.self] = newValue }
    }
}

/// One round of a group chat. The group's own Session runs no model of its own words: each
/// user message gets one `group_relay` call whose result lists the members' replies,
/// `{"replies":[{botId, name, text, time, kind?}]}` (ds-bot's shared/group-replies.js).
struct RoomRelay: Hashable {
    let call: ToolCall
    var replies: [JSON] { call.result.map(Self.replies(in:)) ?? [] }

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

/// A group round: each member's reply under its name and mark.
struct RoomRelayView: View {
    @Environment(AppModel.self) private var app
    let relay: RoomRelay
    let running: Bool

    var body: some View {
        let team = app.botTeam
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(relay.replies.enumerated()), id: \.offset) { _, reply in
                if reply["kind"].isNull {
                    let bot = reply["botId"].string.flatMap(team.bot)
                    HStack(alignment: .top, spacing: 10) {
                        BotAvatar(bot: bot, name: reply["name"].string ?? "?", size: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bot?.name ?? reply["name"].string ?? "").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                            MarkdownView(text: reply["text"].string ?? reply["texts"].array.compactMap(\.string).joined(separator: "\n\n"))
                        }
                    }
                }
            }
            if running && relay.call.result == nil {
                HStack(spacing: 6) {
                    StatusDot(state: .running, size: 6)
                    Text("成员正在发言…").font(.footnote).foregroundStyle(Palette.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    VStack(spacing: 1) {
                        Text(team.name(of: room)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text("\(room.members.count) 个 Bot").font(.caption2).foregroundStyle(Palette.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看群聊设置")),
                accessory: AnyView(RoomMentions(room: room))
            ))
            .environment(\.botTimeline, BotTimeline(room: true))
            .openingOtherSessions($selection, from: room.sessionId)
            .sheet(isPresented: $detailOpen) { RoomDetailView(roomId: roomId) }
            .onAppear { app.clearUnread(room.sessionId) }
            .onDisappear { app.clearUnread(room.sessionId) }
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
    @State private var speaking: [String] = []

    var body: some View {
        let team = app.botTeam
        let members = room.members.compactMap(team.bot)
        VStack(alignment: .leading, spacing: 8) {
            if !speaking.isEmpty {
                HStack(spacing: 6) {
                    StatusDot(state: .running, size: 6)
                    Text("\(speaking.compactMap(team.bot).map(\.name).joined(separator: "、"))正在发言").font(.footnote).foregroundStyle(Palette.secondary)
                }
                .padding(.leading, 6)
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
        // Who speaks in the round, while the group is open.
        .task(id: room.id) {
            while !Task.isCancelled {
                if let rounds = try? await team.call("room-progress", ["roomId": .string(room.id)]) {
                    speaking = rounds.array.flatMap { $0["speaking"].array.compactMap(\.string) }
                }
                try? await Task.sleep(for: .seconds(speaking.isEmpty ? 4 : 1.5))
            }
        }
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
