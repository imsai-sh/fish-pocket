import SwiftUI

/// The sheet: what was shared on top, then where it goes: 新对话 first, then the Bots and the
/// group chats in the Bot page's order. A tap opens the app there.
struct ShareView: View {
    let model: ShareModel
    /// The app's ink, as in the app: an extension does not take `NSAccentColorName` by itself.
    static let ink = Color("AccentColor")

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("发送到 Fish Pocket")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { model.dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(model.phase == .waitingForApp ? Text("完成") : Text("取消"))
                    }
                }
        }
        .tint(Self.ink)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .empty:
            ContentUnavailableView("没能读取分享的内容", systemImage: "exclamationmark.triangle",
                                   description: Text("换一种方式分享，或者在 Fish Pocket 里从文件添加。"))
        case .waitingForApp:
            ContentUnavailableView("已经准备好", systemImage: "checkmark.circle",
                                   description: Text("打开 Fish Pocket 就能在输入框里看到，确认后再发送。"))
        case .reading, .ready:
            List {
                Section {
                    SharedPreview(model: model)
                } footer: {
                    Text("内容会放进输入框，不会自动发送。")
                }
                Section {
                    Button { model.send(to: .newConversation) } label: {
                        TargetRow(title: Text("新对话"), detail: Text("在当前工作区开始")) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color(uiColor: .systemBackground))
                                .frame(width: 36, height: 36)
                                .background(Self.ink, in: Circle())
                        }
                    }
                }
                if !model.targets.bots.isEmpty {
                    Section("Bot") {
                        ForEach(model.targets.bots) { bot in
                            Button { model.send(to: .bot(bot.id)) } label: {
                                TargetRow(title: Text(verbatim: bot.name), detail: bot.role.isEmpty ? nil : Text(verbatim: bot.role)) {
                                    BotPicture(bot: bot)
                                }
                            }
                        }
                    }
                }
                if !model.targets.rooms.isEmpty {
                    Section("群聊") {
                        ForEach(model.targets.rooms) { room in
                            Button { model.send(to: .room(room.id)) } label: {
                                TargetRow(title: Text(verbatim: room.name), detail: room.memberCount > 0 ? Text("\(room.memberCount) 个 Bot") : nil) {
                                    RoomPicture(room: room)
                                }
                            }
                        }
                    }
                }
            }
            .disabled(model.phase != .ready)
        }
    }
}

/// What was shared: the first picture or a symbol, and a line or two saying what it is.
private struct SharedPreview: View {
    let model: ShareModel

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail = model.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .tertiarySystemFill))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                if model.phase == .reading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在读取…").foregroundStyle(.secondary)
                    }
                } else {
                    if let summary { Text(summary).font(.subheadline.weight(.semibold)) }
                    if model.files.count == 1, model.imageCount == 0, let name = model.files.first {
                        Text(verbatim: name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let first = model.texts.first {
                        Text(verbatim: first)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(model.files.isEmpty ? 3 : 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        if !model.files.isEmpty { return "doc" }
        if model.texts.first?.hasPrefix("http") == true { return "link" }
        return "text.alignleft"
    }

    /// 「2 张图片、1 个文件」; nil for text alone, which shows itself.
    private var summary: String? {
        let others = model.files.count - model.imageCount
        var parts: [String] = []
        if model.imageCount > 0 { parts.append(String(localized: "\(model.imageCount) 张图片")) }
        if others > 0 { parts.append(String(localized: "\(others) 个文件")) }
        return parts.isEmpty ? nil : parts.joined(separator: String(localized: "、"))
    }
}

private struct TargetRow<Icon: View>: View {
    let title: Text
    let detail: Text?
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 12) {
            icon.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.foregroundStyle(.primary)
                if let detail { detail.font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// A Bot's avatar as the app drew it (`ShareTargetsWriter`), or its initial.
private struct BotPicture: View {
    let bot: ShareTargets.Bot

    var body: some View {
        if let url = ShareTargets.avatarURL(of: bot.id), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 36, height: 36)
        } else {
            Text(verbatim: String(bot.name.prefix(1)))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.secondary, in: Circle())
        }
    }
}

/// A group's avatar as the app drew it, for this appearance (its outline is the page's colour).
private struct RoomPicture: View {
    let room: ShareTargets.Room
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let url = ShareTargets.avatarURL(ofRoom: room.id, dark: scheme == .dark), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 36, height: 36)
        } else {
            Image(systemName: "person.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
        }
    }
}
