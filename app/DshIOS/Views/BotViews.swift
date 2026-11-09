import SwiftUI

/// Where the Bot pages go: the list, a Bot's own chat, a group chat.
enum BotRoute: Hashable {
    case bot(String)
    case room(String)
}

/// A Bot's mark: the app's own mascot for the main Bot while it keeps the plugin's default
/// look, else its colour and the first character of its name.
struct BotAvatar: View {
    @Environment(AppModel.self) private var app
    private let bot: BotInfo?
    private let name: String
    private let color: Color?
    private let size: CGFloat

    init(name: String, color: Color, size: CGFloat = 40) {
        bot = nil
        self.name = name
        self.color = color
        self.size = size
    }

    init(bot: BotInfo?, name: String? = nil, size: CGFloat = 40) {
        self.bot = bot
        self.name = bot?.name ?? name ?? "?"
        color = nil
        self.size = size
    }

    var body: some View {
        let team = app.botTeam
        Group {
            if let bot, team.usesAppMark(bot) {
                Image("LaunchMark").resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if let data = bot?.avatarImage, let image = BotPicture.image(data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(String(name.prefix(1)))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(color ?? bot.map(team.color(of:)) ?? Palette.secondary, in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

/// A Bot's own picture: a `data:image/…;base64,` URL, decoded once.
enum BotPicture {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ dataURL: String) -> UIImage? {
        if let hit = cache.object(forKey: dataURL as NSString) { return hit }
        guard let comma = dataURL.firstIndex(of: ","), dataURL.hasPrefix("data:image/"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: dataURL as NSString)
        return image
    }

    /// A photo the user picked, as the plugin keeps it: a square JPEG of at most 256 points,
    /// well under its size limit.
    static func dataURL(from data: Data) -> String? {
        guard let source = UIImage(data: data) else { return nil }
        let side = min(source.size.width, source.size.height)
        let crop = CGRect(x: (source.size.width - side) / 2, y: (source.size.height - side) / 2, width: side, height: side)
        let target = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(x: -crop.minX * target.width / side, y: -crop.minY * target.height / side,
                                   width: source.size.width * target.width / side, height: source.size.height * target.height / side))
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.82) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}

/// Two members overlapping, for a group chat.
struct RoomAvatar: View {
    @Environment(AppModel.self) private var app
    let room: RoomInfo
    var size: CGFloat = 40

    var body: some View {
        let team = app.botTeam
        let members = room.members.compactMap(team.bot).prefix(2)
        ZStack(alignment: .topLeading) {
            if members.isEmpty {
                Image(systemName: "person.2.fill").font(.system(size: size * 0.4)).foregroundStyle(Palette.secondary)
                    .frame(width: size, height: size).background(Palette.control, in: Circle())
            } else {
                ForEach(Array(members.enumerated()), id: \.offset) { index, bot in
                    BotAvatar(bot: bot, size: size * 0.68)
                        .overlay(Circle().stroke(Palette.background, lineWidth: 2))
                        .offset(x: index == 0 ? 0 : size * 0.32, y: index == 0 ? 0 : size * 0.32)
                }
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

// MARK: - Drawer entry

/// The Bot entry, under 新会话: one row that opens the Bot pages and says the one thing
/// that matters most right now — what waits on the user, then who is working, then news.
struct BotDrawerEntry: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let team = app.botTeam
        Button {
            Haptics.tap()
            team.openRequest = BotOpenRequest(route: nil)
        } label: {
            HStack(spacing: 12) {
                faces
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bot").font(.headline).foregroundStyle(Palette.ink)
                    status
                }
                Spacer(minLength: 0)
                if team.status == .ready, unread { Circle().fill(Palette.ink).frame(width: 8, height: 8) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 64)
            .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开 Bot 列表")
    }

    /// The main Bot in front, up to two more behind it.
    private var faces: some View {
        let team = app.botTeam
        let main = team.mainBot
        let others = team.bots.filter { $0.id != main?.id }.prefix(2)
        let shown = ([main].compactMap { $0 } + others)
        return ZStack(alignment: .leading) {
            if shown.isEmpty {
                Image("LaunchMark").resizable().scaledToFill().frame(width: 40, height: 40).clipShape(Circle())
            }
            ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { index, bot in
                BotAvatar(bot: bot, size: index == 0 ? 40 : 30)
                    .overlay(Circle().stroke(Palette.grouped, lineWidth: 2))
                    .offset(x: index == 0 ? 0 : CGFloat(28 + (index - 1) * 18), y: index == 0 ? 0 : 7)
            }
        }
        .frame(width: shown.count > 1 ? CGFloat(28 + (shown.count - 2) * 18 + 30) : 40, height: 44, alignment: .leading)
    }

    @ViewBuilder
    private var status: some View {
        let team = app.botTeam
        let waiting = team.bots.filter { bot in
            switch team.rowLine(for: bot) {
            case .question, .needsModel: true
            default: team.pendingView(of: bot) != nil
            }
        }
        let working = team.bots.filter { team.isWorking($0.id) }
        if team.status != .ready {
            Text(team.status == .unknown ? String(localized: "正在准备…") : String(localized: "暂时用不了")).font(.caption).foregroundStyle(Palette.secondary)
        } else if let first = waiting.first {
            Text(waiting.count == 1 ? waitingLine(first) : String(localized: "\(waiting.count) 件事等你处理"))
                .font(.caption).foregroundStyle(Palette.waiting).lineLimit(1)
        } else if let first = working.first {
            HStack(spacing: 5) {
                StatusDot(state: .running, size: 6)
                Text(working.count == 1 ? String(localized: "\(first.name)在干活") : String(localized: "\(working.count) 个 Bot 在干活"))
                    .font(.caption).foregroundStyle(Palette.running).lineLimit(1)
            }
        } else if unread {
            Text("有新消息").font(.caption).foregroundStyle(Palette.secondary)
        } else {
            Text("\(team.bots.count) 个 Bot · \(team.rooms.count) 个群聊").font(.caption).foregroundStyle(Palette.secondary)
        }
    }

    private func waitingLine(_ bot: BotInfo) -> String {
        switch app.botTeam.rowLine(for: bot) {
        case .needsModel: String(localized: "\(bot.name)等你选模型")
        case .question: String(localized: "\(bot.name)等你回答")
        default: String(localized: "\(bot.name)等你填表")
        }
    }

    /// A Bot's chat or a group finished a turn the user has not seen.
    private var unread: Bool {
        let team = app.botTeam
        return team.bots.contains { app.completionUnread.contains($0.sessionId) }
            || team.rooms.contains { app.completionUnread.contains($0.sessionId) }
    }
}

/// The Bot entry on the new conversation page: the main Bot's mascot and the team at a glance.
struct BotHomeEntry: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let team = app.botTeam
        Button {
            Haptics.tap()
            team.openRequest = BotOpenRequest(route: nil)
        } label: {
            HStack(spacing: 12) {
                if let main = team.mainBot {
                    BotAvatar(bot: main, size: 40)
                } else {
                    Image("LaunchMark").resizable().scaledToFill().frame(width: 40, height: 40).clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.mainBot.map { String(localized: "找\($0.name)和 Bot 团队") } ?? String(localized: "Bot 团队"))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(summary).font(.caption).foregroundStyle(team.workingCount > 0 ? Palette.running : Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 60)
            .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        let team = app.botTeam
        guard team.status == .ready else { return String(localized: "常驻替你干活，到点自己开工") }
        if team.workingCount > 0 { return String(localized: "\(team.workingCount) 个在干活") }
        return String(localized: "\(team.bots.count) 个 Bot · \(team.rooms.count) 个群聊")
    }
}

/// Ask the root view to show the Bot pages (nil: the list).
struct BotOpenRequest: Equatable {
    let token = UUID()
    var route: BotRoute?
}

/// What a row says under its name.
enum BotRowLine {
    case none
    case text(String)
    case working
    case question(String)
    case needsModel
}

struct BotRowText: View {
    let title: String
    let line: BotRowLine
    var tag: String?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                if let tag {
                    Text(tag).font(.caption2).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Palette.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            switch line {
            case .none: EmptyView()
            case .text(let text): Text(text).font(compact ? .caption : .subheadline).foregroundStyle(Palette.secondary).lineLimit(1)
            case .working: Text("正在干活…").font(compact ? .caption : .subheadline).foregroundStyle(Palette.running).lineLimit(1)
            case .question(let text): Text("等你回答：\(text)").font(compact ? .caption : .subheadline).foregroundStyle(Palette.waiting).lineLimit(1)
            case .needsModel: Text("等你选模型").font(compact ? .caption : .subheadline).foregroundStyle(Palette.waiting).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension BotModel {
    /// The line a Bot's row shows: what waits on the user, then work, then its role.
    func rowLine(for bot: BotInfo) -> BotRowLine {
        if bot.waiting { return .needsModel }
        if let question = question(of: bot) { return .question(question["question"].string ?? "") }
        if isWorking(bot.id) { return .working }
        return bot.role.isEmpty ? .none : .text(bot.role)
    }
}

// MARK: - Bot list

/// The Bot page: the team's Bots and group chats, or the way to switch the feature on.
struct BotHomeView: View {
    @Environment(AppModel.self) private var app
    let openDrawer: (() -> Void)?
    @State private var creating: CreateKind?
    @State private var showHidden = false

    enum CreateKind: String, Identifiable { case bot, room; var id: String { rawValue } }

    var body: some View {
        let team = app.botTeam
        Group {
            if team.status == .ready {
                list
            } else {
                BotSetupView()
            }
        }
        .background(Palette.background)
        .navigationTitle("Bot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let openDrawer { ToolbarItem(placement: .topBarLeading) { DrawerButton(action: openDrawer) } }
            if team.status == .ready {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { BotTeamSettingsView() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("团队设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { creating = .bot } label: { Label("新建 Bot", systemImage: "person.badge.plus") }
                        Button { creating = .room } label: { Label("新建群聊", systemImage: "person.2") }
                            .disabled(team.bots.count < 2)
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建 Bot 或群聊")
                }
            }
        }
        .sheet(item: $creating) { kind in
            switch kind {
            case .bot: BotCreateSheet()
            case .room: RoomCreateSheet()
            }
        }
        .refreshable { await team.refreshState() }
    }

    /// Pinned first, then the main Bots in their order, then the most recently active.
    private var bots: [BotInfo] {
        let team = app.botTeam
        let main = team.mainBotIds
        return team.bots.filter { showHidden || !$0.hidden }.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let ia = main.firstIndex(of: a.id) ?? .max, ib = main.firstIndex(of: b.id) ?? .max
            if ia != ib { return ia < ib }
            return (app.sessions[a.sessionId]?.updatedAt ?? .distantPast) > (app.sessions[b.sessionId]?.updatedAt ?? .distantPast)
        }
    }

    private var rooms: [RoomInfo] {
        app.botTeam.rooms.filter { showHidden || !$0.hidden }.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return (app.sessions[a.sessionId]?.updatedAt ?? .distantPast) > (app.sessions[b.sessionId]?.updatedAt ?? .distantPast)
        }
    }

    private var list: some View {
        let team = app.botTeam
        let hiddenCount = team.bots.filter(\.hidden).count + team.rooms.filter(\.hidden).count
        return List {
            Section {
                ForEach(bots) { bot in
                    NavigationLink(value: BotRoute.bot(bot.id)) {
                        HStack(spacing: 12) {
                            BotAvatar(bot: bot, size: 44)
                            BotRowText(title: bot.name, line: team.rowLine(for: bot), tag: team.isMain(bot) ? String(localized: "主 Bot") : nil)
                            if bot.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Palette.faint) }
                            trailing(sessionId: bot.sessionId)
                        }
                        .padding(.vertical, 4)
                        .opacity(bot.hidden ? 0.5 : 1)
                    }
                    .swipeActions(edge: .leading) { pinButton(bot.id, pinned: bot.pinned) }
                    .swipeActions(edge: .trailing) { if !team.isMain(bot) { hideButton(bot.id, hidden: bot.hidden) } }
                    .contextMenu {
                        pinButton(bot.id, pinned: bot.pinned)
                        // A main Bot takes the user's work, so it stays in sight.
                        if !team.isMain(bot) { hideButton(bot.id, hidden: bot.hidden) }
                    }
                }
            } header: { Text("Bot") }
            if !rooms.isEmpty {
                Section {
                    ForEach(rooms) { room in
                        NavigationLink(value: BotRoute.room(room.id)) {
                            HStack(spacing: 12) {
                                RoomAvatar(room: room, size: 44)
                                BotRowText(title: team.name(of: room), line: room.preview.map { .text($0) } ?? .none)
                                if room.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Palette.faint) }
                                trailing(sessionId: room.sessionId)
                            }
                            .padding(.vertical, 4)
                            .opacity(room.hidden ? 0.5 : 1)
                        }
                        .swipeActions(edge: .leading) { pinButton(room.id, pinned: room.pinned) }
                        .swipeActions(edge: .trailing) { hideButton(room.id, hidden: room.hidden) }
                        .contextMenu {
                            pinButton(room.id, pinned: room.pinned)
                            hideButton(room.id, hidden: room.hidden)
                        }
                    }
                } header: { Text("群聊") }
            }
            if hiddenCount > 0 {
                Section {
                    Button(showHidden ? String(localized: "收起已隐藏的") : String(localized: "显示 \(hiddenCount) 个已隐藏的")) {
                        withAnimation(.snappy) { showHidden.toggle() }
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func pinButton(_ id: String, pinned: Bool) -> some View {
        Button { Task { await app.botTeam.setFlags(id, pinned: !pinned) } } label: {
            Label(pinned ? "取消置顶" : "置顶", systemImage: pinned ? "pin.slash" : "pin")
        }
        .tint(Palette.ink)
    }

    private func hideButton(_ id: String, hidden: Bool) -> some View {
        Button { Task { await app.botTeam.setFlags(id, hidden: !hidden) } } label: {
            Label(hidden ? "取消隐藏" : "隐藏", systemImage: hidden ? "eye" : "eye.slash")
        }
        .tint(Palette.secondary)
    }

    private func trailing(sessionId: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let date = app.sessions[sessionId]?.updatedAt {
                Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow)).font(.caption2).foregroundStyle(Palette.faint)
            }
            if app.completionUnread.contains(sessionId) { Circle().fill(Palette.ink).frame(width: 8, height: 8) }
        }
    }
}

// MARK: - Setup

/// Shown until the plugin answers: switch it on, or say why the pages cannot open.
struct BotSetupView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let team = app.botTeam
        ScrollView {
            VStack(spacing: 28) {
                HStack(spacing: -14) {
                    BotAvatar(name: "研", color: Color(red: 0.18, green: 0.44, blue: 0.84), size: 64)
                    Image("LaunchMark").resizable().scaledToFill().frame(width: 80, height: 80).clipShape(Circle())
                        .overlay(Circle().stroke(Palette.background, lineWidth: 4)).zIndex(1).accessibilityHidden(true)
                    BotAvatar(name: "码", color: Color(red: 0.72, green: 0.38, blue: 0.04), size: 64)
                }
                .padding(.top, 32)
                VStack(spacing: 10) {
                    Text("一支替你常驻干活的 Bot 团队").font(.title2.bold()).multilineTextAlignment(.center)
                    Text("大肥鱼接活，再分给研究员、程序员这些 Bot。它们记得你的偏好，到点自己开工。")
                        .font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 18) {
                    point("clock", "定时自己开工", "每天的简报、每周的周报，到点就做好")
                    point("person.2", "拉群一起商量", "@ 谁谁回答，几个 Bot 接力把事做完")
                    point("iphone", "全在你手机上", "不连电脑、不经服务器，记忆和文件都存在本机")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .readableWidth()
        }
        .safeAreaInset(edge: .bottom) { action.padding(.horizontal, 20).padding(.bottom, 12).background(Palette.background) }
        .onChange(of: team.status) { _, status in if status == .ready { Haptics.success() } }
    }

    @ViewBuilder
    private var action: some View {
        let team = app.botTeam
        VStack(spacing: 10) {
            switch team.status {
            case .wrongVersion(let version):
                Text("已安装的 Bot 插件是 \(version) 版，Fish Pocket 目前只支持 \(PluginPins.version(of: BotModel.package) ?? "") 版。请先在插件页卸载它，再回来开启。")
                    .font(.footnote).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                Button("打开插件页") { app.pluginStoreRequest = UUID() }.buttonStyle(.capsule())
            case .unknown where !team.installing:
                ProgressView().frame(height: 52)
            default:
                if let error = team.installError {
                    Text(error).font(.footnote).foregroundStyle(Palette.removed).multilineTextAlignment(.center)
                }
                Button {
                    Haptics.tap()
                    Task { if team.status == .disabled { await team.enable() } else { await team.install() } }
                } label: {
                    if team.installing { HStack(spacing: 8) { ProgressView().tint(Palette.onInk); Text("正在开启…") } } else { Text("开启 Bot") }
                }
                .buttonStyle(.capsule())
                .disabled(team.installing)
                Text("开启时会下载 Bot 插件。App 切到后台后，Bot 可能暂停，回到前台会接着做。")
                    .font(.caption).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.callout).foregroundStyle(Palette.ink)
                .frame(width: 36, height: 36).background(Palette.grouped, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(Palette.secondary)
            }
        }
    }
}

// MARK: - Creating

struct BotCreateSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字，比如：研究员", text: $name)
                    TextField("负责什么，比如：查资料、给出处", text: $role)
                } footer: {
                    Text("新 Bot 会先打个招呼，之后可以私聊，也可以拉进群。")
                }
            }
            .navigationTitle("新建 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .saveToolbar(canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty, saving: saving, cancel: { dismiss() }) {
                saving = true
                Task {
                    let done = await app.perform {
                        try await app.botTeam.call("create-bot", ["name": .string(name.trimmingCharacters(in: .whitespaces)), "role": .string(role.trimmingCharacters(in: .whitespaces))])
                    }
                    saving = false
                    if done { await app.botTeam.refreshState(); dismiss() }
                }
            }
        }
    }
}

struct RoomCreateSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: Set<String> = []
    @State private var saving = false

    var body: some View {
        let team = app.botTeam
        NavigationStack {
            Form {
                Section { TextField("群名，比如：产品周会", text: $name) }
                Section {
                    ForEach(team.bots) { bot in
                        Button {
                            if members.contains(bot.id) { members.remove(bot.id) } else { members.insert(bot.id) }
                            Haptics.select()
                        } label: {
                            HStack(spacing: 12) {
                                BotAvatar(bot: bot, size: 32)
                                Text(bot.name).foregroundStyle(Palette.ink)
                                Spacer()
                                Image(systemName: members.contains(bot.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(members.contains(bot.id) ? Palette.ink : Palette.faint)
                            }
                        }
                    }
                } header: { Text("成员") } footer: { Text("至少选两个 Bot。") }
            }
            .navigationTitle("新建群聊")
            .navigationBarTitleDisplayMode(.inline)
            .saveToolbar(canSave: members.count >= 2, saving: saving, cancel: { dismiss() }) {
                saving = true
                Task {
                    var payload: [String: JSON] = ["members": .array(members.map(JSON.string)), "greet": true]
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { payload["name"] = .string(trimmed) }
                    let done = await app.perform { try await app.botTeam.call("create-room", .object(payload)) }
                    saving = false
                    if done { await app.botTeam.refreshState(); dismiss() }
                }
            }
        }
    }
}
