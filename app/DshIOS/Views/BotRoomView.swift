import Observation
import SwiftUI

/// One line of a group chat: the user, a member's post, or a note.
struct RoomItem: Identifiable, Hashable {
    enum Kind: Hashable { case user, post, note }
    let id: String
    let kind: Kind
    var botId: String?
    var name: String?
    var text: String
}

/// A group chat. ds-bot keeps it in the group's own Session, which runs no model: each round
/// is a `group_relay` call whose result lists the members' replies (`{"replies":[{botId, name,
/// text, time, kind?}]}`), and the user's words are its user messages. ds-bot's chat endpoint
/// and feed cover only a Bot's own chat, so the group is read from the Session here and
/// re-read while its members speak.
@MainActor
@Observable
final class BotRoomModel {
    let roomId: String
    private(set) var items: [RoomItem] = []
    private(set) var speaking: [String] = []
    private(set) var loaded = false
    private(set) var error: String?
    @ObservationIgnored private var lastSeq: Int?

    init(roomId: String) {
        self.roomId = roomId
    }

    func load(session sessionId: String, app: AppModel) async {
        do {
            let page = try await app.client.call("session/page", ["request": [
                "address": ["kind": "session", "sessionId": .string(sessionId)],
                "maxMessages": 400,
            ]])
            let events = page["records"].array.map { $0["event"] }
            let seq = events.last?["seq"].int
            if loaded, seq == lastSeq { return }
            lastSeq = seq
            items = Self.parse(events)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// Who speaks in the group's current round.
    func pollProgress(team: BotModel) async -> Bool {
        guard let rounds = try? await team.call("room-progress", ["roomId": .string(roomId)]) else { return false }
        let next = rounds.array.flatMap { $0["speaking"].array.compactMap(\.string) }
        let changed = next != speaking
        speaking = next
        return changed
    }

    static func parse(_ events: [JSON]) -> [RoomItem] {
        var items: [RoomItem] = []
        var relays = Set<String>()
        for event in events {
            let data = event["data"]
            let seq = event["seq"].int ?? items.count
            switch event["type"].string {
            case "tool/call":
                if data["name"].string == "group_relay", let callId = data["callId"].string { relays.insert(callId) }
            case "tool/result":
                let message = data["message"]
                guard let callId = message["toolCallId"].string, relays.contains(callId) else { continue }
                let text = message["content"].array.compactMap { $0["text"].string }.joined()
                for (index, reply) in replies(in: text).enumerated() {
                    let id = "\(seq)-\(index)"
                    let body = reply["text"].string ?? reply["texts"].array.compactMap(\.string).joined(separator: "\n\n")
                    switch reply["kind"].string {
                    case nil:
                        items.append(RoomItem(id: id, kind: .post, botId: reply["botId"].string, name: reply["name"].string, text: body))
                    case "user":
                        if items.last?.kind != .user || items.last?.text != body { items.append(RoomItem(id: id, kind: .user, text: body)) }
                    default:
                        break
                    }
                }
            case "user/message":
                let source = data["source"]
                let text = data["content"].array.compactMap { $0["text"].string }.joined()
                if source["kind"].string == "user" {
                    items.append(RoomItem(id: "\(seq)", kind: .user, text: text))
                } else if source["kind"].string == "bot", source["role"].string == "post" {
                    let body = text.replacingOccurrences(of: #"^\[Group post from [^\]\r\n]*\]\r?\n?"#, with: "", options: .regularExpression)
                    items.append(RoomItem(id: "\(seq)", kind: .post, botId: source["senderSessionId"].string, name: source["senderName"].string, text: body))
                }
            default:
                break
            }
        }
        return items
    }

    /// The replies of a settled `group_relay` result; a result whose middle compaction pruned
    /// still gives the complete reply objects that survived.
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

/// A group chat, drawn natively.
struct BotRoomView: View {
    @Environment(AppModel.self) private var app
    let roomId: String
    @State private var model: BotRoomModel
    @State private var draft = ""
    @State private var sending = false

    init(roomId: String) {
        self.roomId = roomId
        _model = State(initialValue: BotRoomModel(roomId: roomId))
    }

    var body: some View {
        let team = app.botTeam
        Group {
            if let room = team.room(roomId) {
                content(room)
            } else {
                ContentUnavailableView("这个群聊已经不在了", systemImage: "person.2.slash")
            }
        }
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ room: RoomInfo) -> some View {
        let team = app.botTeam
        let members = room.members.compactMap(team.bot)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.loaded && model.items.isEmpty {
                        Text("还没有消息").font(.footnote).foregroundStyle(Palette.faint).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(model.items) { item in row(item, members: members) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
                .readableWidth()
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.items.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { bottom(room, members: members) }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(room.name).font(.subheadline.weight(.semibold))
                    Text("\(members.count) 个 Bot").font(.caption2).foregroundStyle(Palette.secondary)
                }
            }
        }
        // Read the group again when its last line changes, and follow who speaks while it is open.
        .task(id: room.preview) { await model.load(session: room.sessionId, app: app) }
        .task(id: team.feedGeneration) {
            while !Task.isCancelled {
                if await model.pollProgress(team: team) || !model.speaking.isEmpty {
                    await model.load(session: room.sessionId, app: app)
                }
                try? await Task.sleep(for: .seconds(model.speaking.isEmpty ? 4 : 1.5))
            }
        }
        .onAppear { app.clearUnread(room.sessionId) }
        .onDisappear { app.clearUnread(room.sessionId) }
    }

    @ViewBuilder
    private func row(_ item: RoomItem, members: [BotInfo]) -> some View {
        let team = app.botTeam
        switch item.kind {
        case .user:
            Text(highlighted(item.text, members: members))
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
                .textSelection(.enabled)
        case .post:
            let bot = item.botId.flatMap(team.bot)
            HStack(alignment: .top, spacing: 10) {
                BotAvatar(name: bot?.name ?? item.name ?? "?", color: bot.map(team.color(of:)) ?? Palette.secondary, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(bot?.name ?? item.name ?? "").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                    MarkdownView(text: item.text)
                }
            }
        case .note:
            Text(item.text).font(.caption).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity)
        }
    }

    /// `@名字` of a member in the user's line stands out.
    private func highlighted(_ text: String, members: [BotInfo]) -> AttributedString {
        var value = AttributedString(text)
        for member in members where !member.name.isEmpty {
            var searchRange = value.startIndex..<value.endIndex
            while let found = value[searchRange].range(of: "@\(member.name)") {
                value[found].foregroundColor = Color(red: 0.18, green: 0.44, blue: 0.84)
                value[found].font = .callout.weight(.semibold)
                searchRange = found.upperBound..<value.endIndex
            }
        }
        return value
    }

    private func bottom(_ room: RoomInfo, members: [BotInfo]) -> some View {
        let team = app.botTeam
        let speakers = model.speaking.compactMap(team.bot).map(\.name)
        return VStack(alignment: .leading, spacing: 8) {
            if !speakers.isEmpty {
                HStack(spacing: 6) {
                    StatusDot(state: .running, size: 6)
                    Text("\(speakers.joined(separator: "、"))正在发言").font(.footnote).foregroundStyle(Palette.secondary)
                }
                .padding(.leading, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(members) { member in
                        Button {
                            Haptics.select()
                            let prefix = draft.isEmpty || draft.hasSuffix(" ") ? "" : " "
                            draft += "\(prefix)@\(member.name) "
                        } label: {
                            Text("@\(member.name)").font(.footnote).foregroundStyle(Palette.ink)
                                .padding(.horizontal, 12).frame(minHeight: 30)
                                .background(Palette.field, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("说点什么，@ 指定谁来回答", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.vertical, 8)
                Button { send(room) } label: {
                    Image(systemName: "arrow.up").font(.subheadline.weight(.bold)).foregroundStyle(Palette.onInk)
                        .frame(width: 36, height: 36).background(canSend ? Palette.ink : Palette.faint, in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
            .padding(.leading, 18)
            .padding(.trailing, 7)
            .padding(.vertical, 5)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 4)
        .background(Palette.background)
        .readableWidth()
    }

    private var canSend: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send(_ room: RoomInfo) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        sending = true
        Haptics.tap()
        Task {
            if await app.perform({ try await app.botTeam.call("send", ["sessionId": .string(room.sessionId), "text": .string(text)]) }) {
                draft = ""
                clearFocusedTextInput()
                await model.load(session: room.sessionId, app: app)
            }
            sending = false
        }
    }
}
