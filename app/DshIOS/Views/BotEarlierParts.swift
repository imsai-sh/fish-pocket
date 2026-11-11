import SwiftUI

/// The earlier parts of a Bot's chat or a group, above the current one. ds-bot moves a long
/// conversation to a fresh session and keeps the old ones; `earlier` pages through them,
/// newest page first, each page oldest to newest.
struct BotEarlierParts: View {
    @Environment(AppModel.self) private var app
    let sessionId: String
    @State private var items: [JSON] = []
    @State private var cursor: JSON = .null
    @State private var opened = false
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !opened || !cursor.isNull {
                Button { Task { await load() } } label: {
                    HStack(spacing: 6) {
                        if loading { ProgressView().controlSize(.small) } else { Image(systemName: "clock.arrow.circlepath") }
                        Text(opened ? "加载更早的" : "查看更早的对话")
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
            if failed { Text("没能读出更早的对话").font(.caption).foregroundStyle(Palette.removed).frame(maxWidth: .infinity) }
            ForEach(Array(merged.enumerated()), id: \.offset) { _, item in row(item) }
            if opened && !items.isEmpty { divider(String(localized: "以下是现在的对话")) }
        }
    }

    /// Consecutive reply blocks of one turn read as one reply.
    private var merged: [JSON] {
        var out: [JSON] = []
        for item in items {
            if item["kind"].string == "bot", let last = out.last, last["kind"].string == "bot", last["turn"] == item["turn"] {
                out[out.count - 1] = ["kind": "bot", "turn": item["turn"], "time": item["time"],
                                      "text": .string((last["text"].string ?? "") + "\n\n" + (item["text"].string ?? ""))]
            } else {
                out.append(item)
            }
        }
        return out
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var payload: [String: JSON] = ["sessionId": .string(sessionId)]
        if !cursor.isNull { payload["cursor"] = cursor }
        do {
            let page = try await app.botTeam.call("earlier", .object(payload))
            items = page["items"].array + items
            cursor = page["cursor"]
            opened = true
            failed = false
        } catch {
            failed = true
        }
    }

    @ViewBuilder
    private func row(_ item: JSON) -> some View {
        let team = app.botTeam
        switch item["kind"].string {
        case "user":
            Text(item["text"].string ?? "").font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 60)
                .textSelection(.enabled)
        case "bot":
            MarkdownView(text: item["text"].string ?? "")
        case "post":
            let bot = item["botId"].string.flatMap(team.bot)
            let text = item["text"].string.map(Self.withoutLongNote) ?? item["texts"].array.compactMap(\.string).joined(separator: "\n\n")
            RoomMessage(bot: bot, name: bot?.name ?? item["name"].string ?? "?", texts: [text], file: item["file"].nonNull, length: item["length"].int)
        case "answer":
            note(String(localized: "你回答了卡片"), symbol: "checkmark.bubble")
        case "closed":
            note(String(localized: "卡片没有回答"), symbol: "xmark.bubble")
        case "view":
            note(item["title"].string.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "表单"), symbol: "rectangle.on.rectangle")
        case "event":
            let name = item["name"].string ?? String(localized: "其他 Bot")
            switch item["role"].string {
            case "request": note(String(localized: "\(name)交来一件事"), symbol: "arrow.down.message")
            case "reply": note(String(localized: "\(name)回复了"), symbol: "arrowshape.turn.up.left")
            case "report": note(String(localized: "群聊里的回复"), symbol: "person.3")
            default: note(String(localized: "\(name)的工作已停止"), symbol: "stop.circle")
            }
        case "divider":
            divider(String(localized: "更早的一段对话"))
        default:
            EmptyView()
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.footnote).foregroundStyle(Palette.secondary)
    }

    private func divider(_ text: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Palette.stroke).frame(height: 1)
            Text(text).font(.caption2).foregroundStyle(Palette.faint).fixedSize()
            Rectangle().fill(Palette.stroke).frame(height: 1)
        }
    }

    /// A long post starts with the plugin's `[A long message: …]` note.
    static func withoutLongNote(_ text: String) -> String {
        guard text.hasPrefix("[A long message"), let end = text.firstIndex(of: "]") else { return text }
        return String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
