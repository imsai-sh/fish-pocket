import SwiftUI

/// What a Bot asks of the user in its own chat beyond a question or a form: a key, a
/// connector, a mail to approve, a skill it learned. Each ends the Bot's turn until answered.
struct BotRequestCards: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo

    var body: some View {
        let team = app.botTeam
        VStack(spacing: 8) {
            ForEach(team.secretRequests(of: bot), id: \.["id"]) { SecretRequestCard(bot: bot, request: $0) }
            ForEach(team.connectorRequests(of: bot), id: \.["id"]) { ConnectorRequestCard(request: $0) }
            ForEach(team.mailRequests(of: bot), id: \.["id"]) { MailSendCard(bot: bot, request: $0) }
            ForEach((team.live["learning"]?[bot.id].array ?? []), id: \.["id"]) { LearningCard(bot: bot, proposal: $0) }
        }
    }
}

/// A key the Bot needs: typed here, kept on the device, never shown to the model.
private struct SecretRequestCard: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo
    let request: JSON
    @State private var value = ""
    @State private var onlyThisBot = true
    @State private var replacing = false
    @State private var sending = false

    var body: some View {
        let name = request["name"].string ?? ""
        BotCard {
            Text("\(bot.name)需要密钥 \(name)").font(.subheadline.weight(.semibold))
            if let purpose = request["purpose"].string, !purpose.isEmpty { Text(purpose).font(.footnote).foregroundStyle(Palette.secondary) }
            if request["kind"].string == "allow" && !replacing {
                Text("这个密钥已经保存过，允许\(bot.name)使用吗？").font(.footnote)
                HStack(spacing: 8) {
                    Button("允许") { send("secret-allow", ["requestId": request["id"]]) }.buttonStyle(.capsule(height: 36, fill: false))
                    Button("换一个值") { replacing = true }.buttonStyle(.capsule(.outline, height: 36, fill: false))
                    Button("不给") { send("secret-cancel", ["requestId": request["id"]]) }.buttonStyle(.capsule(.outline, height: 36, fill: false))
                }
            } else {
                SecureField("粘贴 \(name)", text: $value)
                    .font(.subheadline).padding(10)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if request["kind"].string != "allow" { Toggle("只给\(bot.name)用", isOn: $onlyThisBot).font(.footnote) }
                HStack(spacing: 8) {
                    Button("保存") {
                        var payload: [String: JSON] = ["requestId": request["id"], "value": .string(value)]
                        if onlyThisBot { payload["scope"] = "bot" }
                        send("secret-set", payload)
                    }
                    .buttonStyle(.capsule(height: 36, fill: false))
                    .disabled(value.count < 4)
                    Button("不给") { send("secret-cancel", ["requestId": request["id"]]) }.buttonStyle(.capsule(.outline, height: 36, fill: false))
                }
                Text("值只存在这台设备上，Bot 在命令里用 $DSH_SECRET_\(name) 读取，模型看不到原文。").font(.caption2).foregroundStyle(Palette.faint)
            }
        }
        .disabled(sending)
    }

    private func send(_ endpoint: String, _ payload: [String: JSON]) {
        sending = true
        Task { await app.botTeam.run(endpoint, payload); sending = false }
    }
}

/// A connector the Bot wants: connecting it on its page settles the card by itself.
private struct ConnectorRequestCard: View {
    @Environment(AppModel.self) private var app
    let request: JSON
    @State private var open = false

    var body: some View {
        let id = request["connectorId"].string ?? ""
        BotCard {
            Text("想连接 \(request["name"].string ?? id)").font(.subheadline.weight(.semibold))
            if let purpose = request["purpose"].string, !purpose.isEmpty { Text(purpose).font(.footnote).foregroundStyle(Palette.secondary) }
            HStack(spacing: 8) {
                Button("去连接") { open = true }.buttonStyle(.capsule(height: 36, fill: false))
                Button("先不连") { Task { await app.botTeam.run("connector-request-cancel", ["requestId": request["id"]]) } }
                    .buttonStyle(.capsule(.outline, height: 36, fill: false))
            }
        }
        .sheet(isPresented: $open) {
            NavigationStack { BotConnectorPage(id: id).closeButton { open = false } }
        }
    }
}

/// A mail the Bot wrote: checked and sent from here, or cancelled.
private struct MailSendCard: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo
    let request: JSON
    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var body_ = ""
    /// What to do with later mails: "" asks each time, `allow-recipient`, or `no-draft`.
    @State private var rule = ""
    @State private var sending = false

    var body: some View {
        BotCard {
            Text("待发送的邮件").font(.subheadline.weight(.semibold))
            field("收件人", text: $to)
            if !cc.isEmpty { field("抄送", text: $cc) }
            field("主题", text: $subject)
            TextField("正文", text: $body_, axis: .vertical).lineLimit(3...10).font(.subheadline)
                .padding(10).background(Palette.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            let files = request["attachmentDetails"].array.compactMap { $0["name"].string }
            if !files.isEmpty { Label(files.joined(separator: "、"), systemImage: "paperclip").font(.caption).foregroundStyle(Palette.secondary) }
            Picker("以后", selection: $rule) {
                Text("每次都先给我看").tag("")
                Text("发给这些收件人不用再确认").tag("allow-recipient")
                Text("\(bot.name)发信都不用再确认").tag("no-draft")
            }
            .font(.footnote)
            HStack(spacing: 8) {
                Button("发送") { answer("send") }.buttonStyle(.capsule(height: 36, fill: false)).disabled(to.isEmpty)
                Button("不发") { answer("cancel") }.buttonStyle(.capsule(.outline, height: 36, fill: false))
            }
        }
        .disabled(sending)
        .onAppear {
            to = request["to"].string ?? request["to"].array.compactMap(\.string).joined(separator: ", ")
            cc = request["cc"].string ?? ""
            subject = request["subject"].string ?? ""
            body_ = request["body"].string ?? ""
        }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(Palette.secondary).frame(width: 44, alignment: .leading)
            TextField("", text: text).font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .padding(10)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func answer(_ choice: String) {
        sending = true
        var payload: [String: JSON] = ["requestId": request["id"], "choice": .string(choice)]
        if choice == "send" {
            payload["fields"] = ["to": .string(to), "cc": .string(cc), "subject": .string(subject), "body": .string(body_)]
            if !rule.isEmpty { payload["rule"] = .string(rule) }
        }
        Task { await app.botTeam.run("mail-send-answer", payload); sending = false }
    }
}

/// Something the Bot learned on its own: a skill to keep, or an edit to the folder's AGENTS.md.
private struct LearningCard: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo
    let proposal: JSON
    @State private var expanded = false
    @State private var sending = false

    var body: some View {
        let skill = proposal["kind"].string == "skill"
        BotCard {
            Text(skill ? "\(bot.name)学会了一个技能：\(proposal["name"].string ?? "")" : "\(bot.name)想更新工作说明 AGENTS.md")
                .font(.subheadline.weight(.semibold))
            if let why = proposal["why"].string ?? proposal["edits"].array.first?["why"].string { Text(why).font(.footnote).foregroundStyle(Palette.secondary) }
            if expanded {
                ScrollView {
                    Text(skill ? (proposal["content"].string ?? "") : proposal["edits"].array.map { edit in
                        let mark = edit["op"].string == "remove" ? "−" : "+"
                        return "\(mark) \(edit["text"].string ?? edit["old"].string ?? "")"
                    }.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            HStack(spacing: 8) {
                Button("采纳") { answer(true) }.buttonStyle(.capsule(height: 36, fill: false))
                Button("不用") { answer(false) }.buttonStyle(.capsule(.outline, height: 36, fill: false))
                Spacer()
                Button(expanded ? "收起" : "看内容") { withAnimation(.snappy) { expanded.toggle() } }.font(.footnote)
            }
        }
        .disabled(sending)
    }

    private func answer(_ approve: Bool) {
        sending = true
        Task { await app.botTeam.run("learning-answer", ["id": proposal["id"], "approve": .bool(approve)]); sending = false }
    }
}

// MARK: - Side chat

/// A quick question on the side of a Bot's chat: answered from what the chat holds so far,
/// with no tools, and nothing goes into the chat itself.
struct BotSideChatSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let botId: String
    @State private var question = ""
    @State private var chatId: String?
    /// A new side chat is being written: the earlier ones stay, out of the way.
    @State private var fresh = false
    @State private var asking = false

    var body: some View {
        let team = app.botTeam
        let chats = team.team["sideChats"][botId].array
        let chat = fresh ? nil : chats.first { $0["id"].string == chatId } ?? chats.last
        let answering = chat?["entries"].array.last?["status"].string == "answering"
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if chat == nil {
                            Text("问一个旁支问题：\(team.bot(botId)?.name ?? "")会根据目前的对话回答，不动手做事，也不会写进聊天记录。")
                                .font(.footnote).foregroundStyle(Palette.secondary)
                        }
                        ForEach(chat?["entries"].array ?? [], id: \.["id"]) { entry in
                            Text(entry["question"].string ?? "").font(.callout)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            switch entry["status"].string {
                            case "answering":
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在回答…").font(.footnote).foregroundStyle(Palette.secondary) }
                                Button("取消") { Task { _ = try? await team.call("side-cancel", ["chatId": chat?["id"] ?? .null, "entryId": entry["id"]]); team.refresh() } }
                                    .font(.footnote)
                            case "failed", "cancelled":
                                Text(entry["error"].string.map(BotErrorText.text) ?? String(localized: "没有回答")).font(.footnote).foregroundStyle(Palette.removed)
                            default:
                                MarkdownView(text: entry["answer"].string ?? "")
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(20)
                }
                .onChange(of: chat?["entries"].array.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    TextField("旁支提问", text: $question, axis: .vertical).lineLimit(1...4)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Palette.field, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    let ready = !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !asking && !answering
                    Button { ask(chat: chat) } label: {
                        Image(systemName: "arrow.up").font(.callout.weight(.bold)).foregroundStyle(Palette.onInk)
                            .frame(width: 36, height: 36).background(ready ? Palette.ink : Palette.faint, in: Circle())
                    }
                    .disabled(!ready)
                }
                .padding(12)
                .background(Palette.background)
            }
            .navigationTitle("旁支提问")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
            .toolbar {
                if !chats.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button { fresh = true; chatId = nil } label: { Label("新的提问", systemImage: "plus") }
                            Section("之前问过的") {
                                ForEach(chats.reversed(), id: \.["id"]) { item in
                                    Button {
                                        fresh = false
                                        chatId = item["id"].string
                                    } label: {
                                        Label(String((item["entries"].array.first?["question"].string ?? String(localized: "还没提问")).prefix(24)),
                                              systemImage: item["id"] == chat?["id"] ? "checkmark" : "bubble.left")
                                    }
                                }
                            }
                            if let id = chat?["id"] {
                                Button(role: .destructive) {
                                    Task { _ = try? await team.call("side-close", ["chatId": id]); chatId = nil; await team.refreshState() }
                                } label: { Label("删除这次提问", systemImage: "trash") }
                            }
                        } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("旁支提问列表")
                    }
                }
            }
        }
    }

    private func ask(chat: JSON?) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        asking = true
        Task {
            var payload: [String: JSON] = ["sessionId": .string(botId), "text": .string(text)]
            if let id = chat?["id"] { payload["chatId"] = id }
            do {
                let value = try await app.botTeam.call("side-ask", .object(payload))
                chatId = value["chatId"].string
                fresh = false
                question = ""
                await app.botTeam.refreshState()
            } catch {
                app.showToast(BotErrorText.text(error.localizedDescription), tone: .warning)
            }
            asking = false
        }
    }
}

import AVFoundation

/// A Bot's reply read aloud, in the voice of the language it is written in.
@MainActor
final class ReadAloud {
    static let shared = ReadAloud()
    private let synthesizer = AVSpeechSynthesizer()

    func toggle(_ text: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate); return }
        enqueue(text)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }

    /// Read after whatever is being read now.
    func enqueue(_ text: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        let plain = text
            .replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[`*_#>|~]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: plain)
        let chinese = plain.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        utterance.voice = AVSpeechSynthesisVoice(language: chinese ? "zh-CN" : AVSpeechSynthesisVoice.currentLanguageCode())
        synthesizer.speak(utterance)
    }
}
