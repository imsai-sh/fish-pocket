import SwiftUI

/// A Bot's own chat: its session in the conversation view, with the Bot as the title
/// and what waits on the user (a model to pick, a question, a form) above the composer.
struct BotChatView: View {
    @Environment(AppModel.self) private var app
    let botId: String
    @State private var detailOpen = false
    /// Held here, not `.constant`: a constant binding reads as changed on every pass, and the
    /// conversation view redraws without end. A session it picks (a reminder's) opens outside.
    @State private var selection: String?

    var body: some View {
        let team = app.botTeam
        if let bot = team.bot(botId) {
            ConversationView(sessionId: bot.sessionId, selection: $selection, openDrawer: nil, bot: BotChrome(
                title: AnyView(Button { detailOpen = true } label: { BotTitle(bot: bot) }
                    .buttonStyle(.plain)
                    .accessibilityHint("查看 Bot 详情")),
                accessory: AnyView(BotPending(bot: bot))
            ))
            .id(bot.sessionId)
            .environment(\.botTimeline, BotTimeline(hiddenTurns: team.hiddenTurns(of: bot)))
            .environment(\.botComposer, .bot(bot.id))
            .openingOtherSessions($selection, from: bot.sessionId)
            .sheet(isPresented: $detailOpen) { BotDetailView(botId: botId) }
            .onAppear { app.clearUnread(bot.sessionId) }
            .onDisappear { app.clearUnread(bot.sessionId) }
        } else {
            ContentUnavailableView("这个 Bot 已不在团队里", systemImage: "person.slash")
        }
    }
}

/// The bar's title: the Bot's mark, name and what it is doing.
private struct BotTitle: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo

    var body: some View {
        let team = app.botTeam
        HStack(spacing: 8) {
            BotAvatar(bot: bot, size: 28)
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
}

/// What waits on the user in this chat. Tool approvals are the conversation view's own.
private struct BotPending: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo

    var body: some View {
        let team = app.botTeam
        VStack(spacing: 8) {
            if bot.waiting { BotModelPicker(bot: bot) }
            if let question = team.question(of: bot) { BotQuestionCard(bot: bot, question: question) }
            if let view = team.pendingView(of: bot) { BotViewCard(bot: bot, pending: view).id(view["id"].string) }
            if let blocked = bot.blocked, !bot.waiting {
                BotCard {
                    Text("\(bot.name)上一轮没能完成").font(.subheadline.weight(.semibold))
                    Text(Self.reason(blocked["code"].string)).font(.footnote).foregroundStyle(Palette.secondary)
                    Button("修好了，重试") {
                        Haptics.tap()
                        Task { await team.run("resume", ["botId": .string(bot.id)]) }
                    }
                    .buttonStyle(.capsule(height: 36, fill: false))
                }
            }
        }
    }
}

extension BotPending {
    /// Why the last turn failed, for the codes ds-bot reports as fixable.
    static func reason(_ code: String?) -> String {
        switch code {
        case "MISSING_CREDENTIAL", "INVALID_CREDENTIAL", "AUTH":
            String(localized: "模型的 API Key 缺失或无效。到设置 › 模型检查，或者在它的资料页换个模型。")
        case "QUOTA", "ACCOUNT_QUOTA":
            String(localized: "模型的额度用完了。充值或换个模型后再试。")
        case "ACCOUNT_SIGN_IN_REQUIRED", "ACCOUNT_SIGNED_OUT", "ACCOUNT_TOKEN_INVALID":
            String(localized: "DeepSeek 账号需要重新登录。到设置 › 账号登录后再试。")
        default:
            String(localized: "运行出错了（\(code ?? "?")）。")
        }
    }
}

/// A rounded card above the composer.
struct BotCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A question the Bot asked (ds-bot's `ask_user`): its options as buttons.
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
