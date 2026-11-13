import SwiftUI
import UniformTypeIdentifiers

// MARK: - Reactions

/// A mark the reader leaves on a Bot's reply. It is the reader's own note: kept on this
/// device, never sent to the Bot (ds-bot's window keeps its reactions the same way).
@MainActor
@Observable
final class BotReactions {
    static let shared = BotReactions()
    static let choices = ["👍", "❤️", "😂", "🎉", "🤔", "👀"]
    private static let storeKey = "bot.reactions"

    private(set) var all: [String: String]

    private init() {
        all = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
    }

    static func key(session: String, turn: Int) -> String { "\(session):\(turn)" }
    static func key(session: String, call: String, index: Int) -> String { "\(session):\(call):\(index)" }

    func toggle(_ emoji: String, for key: String) {
        Haptics.select()
        if all[key] == emoji { all[key] = nil } else { all[key] = emoji }
        UserDefaults.standard.set(all, forKey: Self.storeKey)
    }
}

/// The six reactions as one row of a context menu.
struct BotReactionMenu: View {
    let key: String

    var body: some View {
        // Three to a row: a compact row holds four at most, and six would wrap unevenly.
        ForEach([Array(BotReactions.choices.prefix(3)), Array(BotReactions.choices.dropFirst(3))], id: \.self) { row in
            ControlGroup {
                ForEach(row, id: \.self) { emoji in
                    Button(emoji) { BotReactions.shared.toggle(emoji, for: key) }
                }
            }
            .controlGroupStyle(.compactMenu)
        }
    }
}

/// The reaction left on a reply, under it; a tap takes it away.
struct BotReactionChip: View {
    let key: String

    var body: some View {
        if let emoji = BotReactions.shared.all[key] {
            Button { BotReactions.shared.toggle(emoji, for: key) } label: {
                Text(emoji).font(.callout)
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .background(Palette.grouped, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消回应 \(emoji)")
        }
    }
}

// MARK: - Thinking time

/// How long a reply's reasoning took, as ds-bot timed it: a line at the end of its steps.
struct BotThinkingTime: View {
    @Environment(AppModel.self) private var app
    @Environment(\.botTimeline) private var bot
    let turn: Int
    @State private var seconds: Int?

    var body: some View {
        // A stack, not a group: with nothing in it yet a group is no view at all, and the read
        // below would never start.
        VStack(spacing: 0) {
            if let seconds, seconds > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "brain").frame(width: 20)
                    Text("思考了 \(TimelineFormat.duration(seconds))")
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .foregroundStyle(Palette.secondary)
                .frame(minHeight: 36)
            }
        }
        .task(id: turn) {
            guard seconds == nil, let sessionId = bot?.sessionId, !sessionId.isEmpty else { return }
            let value = try? await app.botTeam.call("thinking", ["sessionId": .string(sessionId), "turn": .number(Double(turn))])
            // Under a second still reads as a second: the line says the reply thought, and about how long.
            if let ms = value?["ms"].double, ms > 0 { seconds = max(1, Int((ms / 1000).rounded())) }
        }
    }
}

// MARK: - Where a message came from

extension IMPlatform {
    /// The chat app a user message came in over: such a message carries `im:<platform>:<id>`
    /// as its request id.
    static func via(_ requestId: String?) -> String? {
        guard let requestId, requestId.hasPrefix("im:") else { return nil }
        let parts = requestId.split(separator: ":")
        return parts.count > 1 ? name(String(parts[1])) : nil
    }
}

// MARK: - Markdown

/// A reply or a whole conversation as a `.md` file, for the share sheet.
struct MarkdownFile: Transferable {
    let name: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { file in
            let safe = file.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe.isEmpty ? "reply" : safe).appendingPathExtension("md")
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

extension SessionModel {
    /// The loaded conversation as Markdown: who said what, without the work in between.
    @MainActor
    func markdown(title: String, team: BotModel, botName: String?, hidden: Set<Int> = []) -> String {
        var parts = ["# \(title)"]
        let timeline = BotTimeline(hiddenTurns: hidden)
        for item in items where !timeline.hides(item) {
            switch item {
            case .questionReply(let reply):
                parts.append("**\(String(localized: "你"))**\n\n\(reply.copyText)")
            case .user(_, let text, _, _) where !text.isEmpty:
                parts.append("**\(String(localized: "你"))**\n\n\(text)")
            case .assistant(_, let blocks, _, _):
                if let relay = RoomRelay(blocks: blocks) {
                    for reply in relay.replies where reply["kind"].isNull {
                        let name = reply["botId"].string.flatMap(team.bot)?.name ?? reply["name"].string ?? "Bot"
                        parts.append("**\(name)**\n\n\(BotEarlierParts.withoutLongNote(reply["text"].string ?? ""))")
                    }
                } else {
                    let text = blocks.compactMap { if case .text(_, let text) = $0 { text } else { nil } }.joined(separator: "\n\n")
                    if !text.isEmpty { parts.append("**\(botName ?? "Bot")**\n\n\(text)") }
                }
            default: break
            }
        }
        return parts.joined(separator: "\n\n---\n\n") + "\n"
    }
}

// MARK: - Reading replies aloud

/// A Bot's replies read aloud as they arrive, for a chat the user follows by ear: only while
/// that chat is the one on screen.
@MainActor
@Observable
final class BotAutoRead {
    static let shared = BotAutoRead()
    /// The sessions whose replies are read.
    private(set) var sessions: Set<String> = []
    @ObservationIgnored private var listener: UUID?

    func isOn(_ sessionId: String) -> Bool { sessions.contains(sessionId) }

    func toggle(_ sessionId: String, team: BotModel) {
        Haptics.select()
        if sessions.contains(sessionId) {
            sessions.remove(sessionId)
            ReadAloud.shared.stop()
        } else {
            sessions.insert(sessionId)
        }
        if sessions.isEmpty, let listener {
            team.removeListener(listener)
            self.listener = nil
        } else if listener == nil, !sessions.isEmpty {
            listener = team.addListener { [weak self] sessionId, item in
                guard let self, self.sessions.contains(sessionId), ReadAloud.shared.scope == sessionId,
                      item["kind"].string == "bot", let text = item["text"].string else { return }
                ReadAloud.shared.enqueue(text)
            }
        }
    }
}
