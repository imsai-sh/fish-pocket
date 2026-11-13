import SwiftUI

/// Where the Bot pages go: the list, a Bot's own chat, a group chat.
enum BotRoute: Hashable {
    case bot(String)
    case room(String)
}

/// A Bot's mark: the app's own mascot for the main Bot while it keeps the plugin's default
/// look, else its photo, else its character in its colour. `live` marks move for what the
/// Bot is doing, and the large ones blink and fidget at rest; the rest stay still, so a long
/// page does not run dozens of animations.
struct BotAvatar: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo?
    /// Shown by its first character when the Bot is not on the team (any more).
    var name: String?
    var size: CGFloat = 40
    var live = false
    /// Set where the page knows better than the team's feed what the Bot is doing.
    var mood: BotMood?
    /// The page's colour, drawn around the mark where marks overlap.
    var outline: Color?

    var body: some View {
        let team = app.botTeam
        let mood = mood ?? (live ? bot.map { team.mood($0.id) } : nil) ?? .idle
        Group {
            if let bot, team.usesAppMark(bot) {
                picture(Image("LaunchMark"), mood: mood)
            } else if let data = bot?.avatarImage, let image = BotPicture.image(data) {
                picture(Image(uiImage: image), mood: mood)
            } else if let bot {
                BotMark(character: team.character(of: bot), color: team.color(of: bot), size: size, mood: mood,
                        lively: live && size >= 64, seed: bot.id, outline: outline)
            } else {
                Text(String((name ?? "?").prefix(1)))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Palette.secondary, in: Circle())
            }
        }
        .accessibilityHidden(true)
    }

    private func picture(_ image: Image, mood: BotMood) -> some View {
        image.resizable().scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay { if let outline { Circle().stroke(outline, lineWidth: 2) } }
            .modifier(BotPictureMotion(mood: mood, size: size))
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
                    BotAvatar(bot: bot, size: size * 0.68, outline: Palette.background)
                        .offset(x: index == 0 ? 0 : size * 0.32, y: index == 0 ? 0 : size * 0.32)
                }
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

// MARK: - Drawer entry

/// The Bot entry, first of the drawer's rows: a row like 插件 and the others under it, the
/// main Bot's face where they have an icon, and on the right the one thing that matters most
/// right now — what waits on the user, then who is working, then news.
struct BotDrawerEntry: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let team = app.botTeam
        Button {
            Haptics.tap()
            team.openRequest = BotOpenRequest(route: nil)
        } label: {
            // The faces are the name: no "Bot" beside them, and nothing on the right
            // unless something is going on.
            HStack(spacing: 12) {
                faces
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Bot"))
                Spacer(minLength: 8)
                status
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开 Bot 列表")
    }

    /// The main Bot in front, up to two more tucked behind it, where the rows under it have
    /// their icon; wider than that icon, so the title sits further in than theirs. Behind it
    /// go the Bots the status on the right is about: those waiting on the user, then those
    /// working, then the rest in the team's order.
    private var faces: some View {
        let team = app.botTeam
        let main = team.mainBot
        let rest = team.bots.filter { $0.id != main?.id }
        let waiting = rest.filter { team.pendingCount(of: $0) > 0 }
        let working = rest.filter { team.pendingCount(of: $0) == 0 && team.isWorking($0.id) }
        let others = (waiting + working + rest.filter { team.pendingCount(of: $0) == 0 && !team.isWorking($0.id) }).prefix(2)
        let shown = ([main].compactMap { $0 } + others)
        return HStack(spacing: -20) {
            if shown.isEmpty {
                Image("LaunchMark").resizable().scaledToFill().frame(width: 56, height: 56).clipShape(Circle())
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, bot in
                BotAvatar(bot: bot, size: 56, live: true, outline: Palette.background)
                    .zIndex(Double(shown.count - index))
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        let team = app.botTeam
        let waiting = team.bots.filter { team.pendingCount(of: $0) > 0 }
        let pending = waiting.reduce(0) { $0 + team.pendingCount(of: $1) }
        let working = team.bots.filter { team.isWorking($0.id) }
        if team.status != .ready {
            Text(team.status == .unknown ? String(localized: "正在准备…") : String(localized: "暂时用不了")).font(.footnote).foregroundStyle(Palette.secondary)
        } else if let first = waiting.first {
            Text(pending == 1 ? waitingLine(first) : String(localized: "\(pending) 件事等你处理"))
                .font(.footnote).foregroundStyle(Palette.waiting).lineLimit(1)
        } else if let first = working.first {
            HStack(spacing: 5) {
                StatusDot(state: .running, size: 6)
                Text(working.count == 1 ? String(localized: "\(first.name)在干活") : String(localized: "\(working.count) 个 Bot 在干活"))
                    .font(.footnote).foregroundStyle(Palette.running).lineLimit(1)
            }
        } else if unread {
            HStack(spacing: 6) {
                Circle().fill(Palette.ink).frame(width: 7, height: 7)
                Text("有新消息").font(.footnote).foregroundStyle(Palette.ink)
            }
        }
    }

    private func waitingLine(_ bot: BotInfo) -> String {
        switch app.botTeam.rowLine(for: bot) {
        case .needsModel: String(localized: "\(bot.name)等你选模型")
        case .question: String(localized: "\(bot.name)等你回答")
        case .waiting(let text): "\(bot.name)：\(text)"
        default: String(localized: "\(bot.name)等你处理")
        }
    }

    /// A Bot's chat or a group finished a turn the user has not seen.
    private var unread: Bool {
        let team = app.botTeam
        return team.bots.contains { app.completionUnread.contains($0.sessionId) }
            || team.rooms.contains { app.completionUnread.contains($0.sessionId) }
    }
}

/// Ask the root view to show the Bot pages (nil: the list).
struct BotOpenRequest: Equatable {
    let token = UUID()
    var route: BotRoute?
    /// On top of the page that is open, so going back returns to it.
    var push = false
}

/// What a row says under its name.
enum BotRowLine {
    case none
    case text(String)
    case working
    case question(String)
    case needsModel
    /// Something else waits on the user, said in a few words.
    case waiting(String)
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
            case .waiting(let text): Text(text).font(compact ? .caption : .subheadline).foregroundStyle(Palette.waiting).lineLimit(1)
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
        if pendingView(of: bot) != nil { return .waiting(String(localized: "等你填一张卡片")) }
        if work["approvals"].array.contains(where: { $0["botId"].string == bot.id }) { return .waiting(String(localized: "等你批准")) }
        if !secretRequests(of: bot).isEmpty { return .waiting(String(localized: "等你给一个密钥")) }
        if !connectorRequests(of: bot).isEmpty { return .waiting(String(localized: "等你连接一个服务")) }
        if !mailRequests(of: bot).isEmpty { return .waiting(String(localized: "有一封邮件等你确认")) }
        if bot.blocked != nil { return .waiting(String(localized: "上一轮没做完，等你处理")) }
        if !(live["learning"]?[bot.id].array ?? []).isEmpty { return .waiting(String(localized: "学到了新东西，等你看")) }
        switch doing(bot.id) {
        case .working: return workPhrase(bot.id).map { .text($0 + "…") } ?? .working
        case .waiting: return .text(doingText(bot.id) ?? "")
        default: return bot.role.isEmpty ? .none : .text(bot.role)
        }
    }
}

// MARK: - Bot list

/// The Bot page: the team's Bots and group chats, or the way to switch the feature on.
struct BotHomeView: View {
    @Environment(AppModel.self) private var app
    let openDrawer: (() -> Void)?
    @State private var creating: CreateKind?
    @State private var settingsOpen = false
    @State private var showHidden = false
    @State private var query = ""
    /// What was said in the Bots' own chats that holds the search words, newest first.
    @State private var hits: [ChatHit] = []
    /// The chat pages read for this search, by Bot: read once while the search field is in use.
    @State private var chatPages: [String: [JSON]] = [:]

    struct ChatHit: Identifiable {
        let id: String
        let botId: String
        let mine: Bool
        let snippet: String
        let time: Double
    }

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
                    Menu {
                        Button { creating = .bot } label: { Label("新建 Bot", systemImage: "person.badge.plus") }
                        Button { creating = .room } label: { Label("新建群聊", systemImage: "person.2") }
                            .disabled(team.bots.count < 2)
                        Divider()
                        Button { settingsOpen = true } label: { Label("团队设置", systemImage: "gearshape") }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .sheet(item: $creating) { kind in
            Group {
                switch kind {
                case .bot: BotCreateSheet()
                case .room: RoomCreateSheet()
                }
            }
            .settingsStyle()
        }
        // Its own sheet, as 设置 is: the pages inside are the system's lists.
        .sheet(isPresented: $settingsOpen) { SheetStack { BotTeamSettingsView() }.settingsStyle() }
        .refreshable { await team.refreshState() }
        .task(id: query) { await searchMessages() }
        // A key or a provider set in 设置 changes the models a Bot can run on; nothing on the
        // feed says so, so the list is read again when DSH says they changed.
        .task(id: app.revision("llm/adapters-updated", "credentials/reference-updated", "credentials/record-updated")) {
            guard team.status == .ready else { return }
            _ = try? await team.call("models")
            await team.refreshState()
        }
    }

    private var needle: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    /// What the user and each Bot said in its own chat, searched here: the engine on a phone
    /// keeps no session index, so the chats' recent pages are read (ds-bot's `chat`) and matched.
    /// A group's messages are not in those pages; groups match by name, members and last line.
    private func searchMessages() async {
        let words = needle
        guard words.count >= 2 else {
            hits = []
            if words.isEmpty { chatPages = [:] }
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        let team = app.botTeam
        var found: [ChatHit] = []
        for bot in team.bots {
            if chatPages[bot.id] == nil {
                var items: [JSON] = []
                var cursor: JSON = .null
                for _ in 0..<3 {
                    var payload: [String: JSON] = ["botId": .string(bot.id)]
                    if !cursor.isNull { payload["cursor"] = cursor }
                    guard let page = try? await team.call("chat", .object(payload)) else { break }
                    items = page["items"].array + items
                    cursor = page["cursor"]
                    if cursor.isNull { break }
                }
                if Task.isCancelled { return }
                chatPages[bot.id] = items
            }
            for (index, item) in (chatPages[bot.id] ?? []).enumerated() {
                guard let kind = item["kind"].string, kind == "user" || kind == "bot", let text = item["text"].string,
                      let range = text.range(of: words, options: .caseInsensitive) else { continue }
                let from = text.index(range.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
                let to = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
                let snippet = (from > text.startIndex ? "…" : "") + text[from..<to].replacingOccurrences(of: "\n", with: " ") + (to < text.endIndex ? "…" : "")
                found.append(ChatHit(id: "\(bot.id):\(index)", botId: bot.id, mine: kind == "user", snippet: snippet, time: item["time"].double ?? 0))
            }
        }
        hits = Array(found.sorted { $0.time > $1.time }.prefix(30))
    }

    /// Pinned first, then the main Bots in their order, then the most recently active.
    private var bots: [BotInfo] {
        let team = app.botTeam
        let needle = needle
        return team.bots.filter { (showHidden || !$0.hidden || !needle.isEmpty) && (needle.isEmpty || $0.name.lowercased().contains(needle) || $0.role.lowercased().contains(needle)) }
            .sorted(by: team.listOrder)
    }

    private var rooms: [RoomInfo] {
        let team = app.botTeam
        let needle = needle
        return team.rooms.filter { room in
            (showHidden || !room.hidden || !needle.isEmpty)
                && (needle.isEmpty || team.name(of: room).lowercased().contains(needle) || (room.preview ?? "").lowercased().contains(needle)
                    || room.members.contains { team.bot($0)?.name.lowercased().contains(needle) == true })
        }.sorted(by: team.listOrder)
    }

    private var list: some View {
        let team = app.botTeam
        let hiddenCount = team.bots.filter(\.hidden).count + team.rooms.filter(\.hidden).count
        return List {
            if let reason = team.readOnly {
                Section {
                    Label("另一个 DSH 正在管理这支团队，这里暂时只能看。", systemImage: "lock")
                        .font(.footnote).foregroundStyle(Palette.waiting)
                        .accessibilityHint(reason)
                }
            }
            if !bots.isEmpty { Section {
                ForEach(bots) { bot in
                    NavigationLink(value: BotRoute.bot(bot.id)) {
                        HStack(spacing: 12) {
                            BotAvatar(bot: bot, size: 44, live: true)
                            BotRowText(title: bot.name, line: team.rowLine(for: bot), tag: team.isMain(bot) ? String(localized: "主 Bot") : nil)
                            if bot.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Palette.faint) }
                            trailing(sessionId: bot.sessionId)
                        }
                        .padding(.vertical, 4)
                        .opacity(bot.hidden ? 0.5 : 1)
                    }
                    // Only a left swipe: a right swipe is the one that opens the sidebar.
                    .swipeActions(edge: .trailing) {
                        if !team.isMain(bot) { hideButton(bot.id, hidden: bot.hidden) }
                        pinButton(bot.id, pinned: bot.pinned)
                    }
                    .contextMenu {
                        pinButton(bot.id, pinned: bot.pinned)
                        // A main Bot takes the user's work, so it stays in sight.
                        if !team.isMain(bot) { hideButton(bot.id, hidden: bot.hidden) }
                        sessionButtons(bot.sessionId)
                    }
                }
            } header: { Text("Bot") } }
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
                        .swipeActions(edge: .trailing) {
                            hideButton(room.id, hidden: room.hidden)
                            pinButton(room.id, pinned: room.pinned)
                        }
                        .contextMenu {
                            pinButton(room.id, pinned: room.pinned)
                            hideButton(room.id, hidden: room.hidden)
                            sessionButtons(room.sessionId)
                        }
                    }
                } header: { Text("群聊") }
            }
            if !hits.isEmpty {
                Section("私聊里说过的") {
                    ForEach(hits) { hit in
                        NavigationLink(value: BotRoute.bot(hit.botId)) {
                            HStack(alignment: .top, spacing: 10) {
                                BotAvatar(bot: team.bot(hit.botId), size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(team.bot(hit.botId)?.name ?? "").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                                        if hit.mine { Text("你说的").font(.caption2).foregroundStyle(Palette.faint) }
                                        Spacer(minLength: 0)
                                        if hit.time > 0 {
                                            Text(Date(timeIntervalSince1970: hit.time / 1000), format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(Palette.faint)
                                        }
                                    }
                                    Text(hit.snippet).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            if !needle.isEmpty && bots.isEmpty && rooms.isEmpty && hits.isEmpty {
                Section { Text("没有找到「\(query)」").font(.footnote).foregroundStyle(Palette.secondary) }
            }
            if hiddenCount > 0 && needle.isEmpty {
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
        .searchable(text: $query, prompt: "搜索 Bot、群聊和私聊记录")
    }

    @ViewBuilder
    private func sessionButtons(_ sessionId: String) -> some View {
        if !app.completionUnread.contains(sessionId) {
            Button { app.markUnread(sessionId) } label: { Label("标为未读", systemImage: "circle.fill") }
        }
        Button { copyToPasteboard(sessionId); app.showToast(String(localized: "已复制")) } label: { Label("复制会话 ID", systemImage: "number") }
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
                    BotMark(character: BotCharacter.named("star")!, color: BotInk.color("blue")!, size: 64, lively: true, seed: "star")
                    Image("LaunchMark").resizable().scaledToFill().frame(width: 80, height: 80).clipShape(Circle())
                        .overlay(Circle().stroke(Palette.background, lineWidth: 4)).zIndex(1).accessibilityHidden(true)
                    BotMark(character: BotCharacter.named("kitty")!, color: BotInk.color("orange")!, size: 64, lively: true, seed: "kitty")
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
                Text("App 切到后台后，Bot 可能暂停，回到前台会接着做。")
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

/// A look for a Bot without a photo: one of the characters in one of the team's colours.
struct BotLookPicker: View {
    @Environment(AppModel.self) private var app
    /// A character's id; anything else (a photo, the app's mascot): none of these is picked.
    @Binding var shape: String?
    @Binding var color: String?

    var body: some View {
        let team = app.botTeam
        let ink = BotInk.color(color) ?? Palette.secondary
        VStack(spacing: 16) {
            // The whale stays the main Bot's.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 10) {
                ForEach(BotCharacter.all.filter { $0.id != "whale" }) { character in
                    Button { Haptics.select(); shape = character.id } label: {
                        BotMark(character: character, color: ink, size: 40, ringed: shape == character.id)
                            .scaleEffect(shape == character.id ? 0.86 : 1)
                            .frame(width: 52, height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(character.id)
                    .accessibilityAddTraits(shape == character.id ? .isSelected : [])
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: shape)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 12) {
                ForEach(team.colorKeys, id: \.self) { key in
                    Button { Haptics.select(); color = key } label: {
                        Circle().fill(BotInk.color(key) ?? Palette.secondary).frame(width: 26, height: 26)
                            .overlay(Circle().stroke(BotInk.color(key) ?? Palette.secondary, lineWidth: color == key ? 2 : 0).padding(-5))
                            .frame(width: 44, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key)
                    .accessibilityAddTraits(color == key ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// The look being picked, large: it pops as the look changes, and spins when poked.
struct BotLookPreview: View {
    let shape: String?
    let color: String?
    var mood = BotMood.idle
    @State private var poke = 0

    var body: some View {
        Button { Haptics.tap(); poke += 1 } label: {
            BotMark(character: BotCharacter.named(shape) ?? BotCharacter.all[0], color: BotInk.color(color) ?? Palette.secondary, size: 104,
                    mood: mood, lively: true, seed: shape ?? "", poke: poke)
                .phaseAnimator([false, true], trigger: [shape, color]) { mark, popped in
                    mark.scaleEffect(popped ? 1.14 : 1).rotationEffect(.degrees(popped ? -9 : 0))
                } animation: { popped in
                    popped ? .spring(response: 0.16, dampingFraction: 0.7) : .spring(response: 0.42, dampingFraction: 0.42)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}

struct BotCreateSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var shape: String? = BotCharacter.friendly.randomElement()
    @State private var color: String?
    @State private var model = ""
    @State private var instructions = ""
    @State private var brief = ""
    @State private var saving = false

    var body: some View {
        let team = app.botTeam
        let fallback = team.prefs["defaultBotModel"].string ?? team.team["defaultModel"].string
        NavigationStack {
            Form {
                Section {
                    BotLookPreview(shape: shape, color: color, mood: saving ? .working : .idle)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    TextField("名字，比如：研究员", text: $name)
                    TextField("负责什么，比如：查资料、给出处", text: $role)
                }
                Section("形象") { BotLookPicker(shape: $shape, color: $color) }
                Section {
                    Picker("模型", selection: $model) {
                        Text(fallback.flatMap(team.modelName).map { String(localized: "默认（\($0)）") } ?? String(localized: "稍后再选")).tag("")
                        ForEach(team.models.compactMap { item in item["ref"].string.map { (ref: $0, name: item["name"].string ?? $0) } }, id: \.ref) { item in
                            Text(item.name).tag(item.ref)
                        }
                    }
                    .pickerValueTint()
                }
                Section {
                    TextField("它做事时要遵守的要求、偏好和背景", text: $instructions, axis: .vertical).lineLimit(3...8)
                } header: { Text("工作说明（可不填）") }
                Section {
                    TextField("比如：帮我整理这周的行业新闻", text: $brief, axis: .vertical).lineLimit(2...6)
                } header: { Text("先交给它一件事（可不填）") } footer: {
                    Text("不填的话，新 Bot 会先打个招呼。之后可以私聊，也可以拉进群。")
                }
            }
            .navigationTitle("新建 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .saveToolbar(canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty, saving: saving, cancel: { dismiss() }) { create() }
            .onAppear { if color == nil { color = team.colorKeys.filter { !["charcoal", "graphite", "black", "gray", "brown"].contains($0) }.randomElement() } }
        }
    }

    private func create() {
        let team = app.botTeam
        var payload: [String: JSON] = ["name": .string(name.trimmingCharacters(in: .whitespaces)), "role": .string(role.trimmingCharacters(in: .whitespaces))]
        if let color { payload["color"] = .string(color) }
        if let shape { payload["avatar"] = ["shape": .string(shape)] }
        if !model.isEmpty { payload["model"] = .string(model) }
        let rules = instructions.trimmingCharacters(in: .whitespacesAndNewlines), first = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rules.isEmpty { payload["instructions"] = .string(rules) }
        if !first.isEmpty { payload["brief"] = .string(first) }
        saving = true
        Task {
            do {
                let bot = try await team.call("create-bot", .object(payload))
                await team.refreshState()
                dismiss()
                if let id = bot["id"].string { team.openRequest = BotOpenRequest(route: .bot(id), push: true) }
            } catch {
                app.showToast(error.localizedDescription, tone: .warning)
            }
            saving = false
        }
    }
}

/// A new group: who is in it, who takes plain messages first, and what to start with.
struct RoomCreateSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: [String] = []
    /// Empty: ds-bot picks (a main Bot among the members, else the first).
    @State private var admin = ""
    @State private var first = ""
    @State private var saving = false

    var body: some View {
        let team = app.botTeam
        NavigationStack {
            Form {
                Section { TextField("群名，不填就用成员的名字", text: $name) }
                Section {
                    ForEach(team.bots.filter { $0.json["private"].bool != true }) { bot in
                        Button {
                            if let index = members.firstIndex(of: bot.id) { members.remove(at: index); if admin == bot.id { admin = "" } } else { members.append(bot.id) }
                            Haptics.select()
                        } label: {
                            HStack(spacing: 12) {
                                BotAvatar(bot: bot, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(bot.name).foregroundStyle(Palette.ink)
                                    if !bot.role.isEmpty { Text(bot.role).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1) }
                                }
                                Spacer()
                                Image(systemName: members.contains(bot.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(members.contains(bot.id) ? Palette.ink : Palette.faint)
                            }
                        }
                    }
                } header: { Text("成员") } footer: { Text("选两个到十二个 Bot。私有 Bot 不能进群。") }
                if members.count >= 2 {
                    Section {
                        Picker("群主", selection: $admin) {
                            Text("自动选择").tag("")
                            ForEach(members, id: \.self) { id in Text(team.bot(id)?.name ?? id).tag(id) }
                        }
                        .pickerValueTint()
                    } footer: { Text("你发的消息先交给群主，群主再点名需要的成员。建好后还能改。") }
                    Section {
                        TextField("比如：大家一起把下周的发布计划过一遍", text: $first, axis: .vertical).lineLimit(2...6)
                    } header: { Text("第一句话（可不填）") } footer: { Text("不填的话，成员们会先打个招呼。") }
                }
            }
            .navigationTitle("新建群聊")
            .navigationBarTitleDisplayMode(.inline)
            .saveToolbar(canSave: (2...12).contains(members.count), saving: saving, cancel: { dismiss() }) { create() }
        }
    }

    private func create() {
        let team = app.botTeam
        let opening = first.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: JSON] = ["members": .array(members.map(JSON.string)), "greet": .bool(opening.isEmpty)]
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { payload["name"] = .string(trimmed) }
        if !admin.isEmpty { payload["admin"] = .string(admin) }
        saving = true
        Task {
            do {
                let room = try await team.call("create-room", .object(payload))
                await team.refreshState()
                dismiss()
                guard let id = room["id"].string else { return }
                team.openRequest = BotOpenRequest(route: .room(id), push: true)
                if !opening.isEmpty { _ = try? await team.call("send", ["sessionId": .string(id), "text": .string(opening)]) }
            } catch {
                app.showToast(error.localizedDescription, tone: .warning)
            }
            saving = false
        }
    }
}
