import Foundation
import Observation
import SwiftUI

/// One Bot of the team, as ds-bot's `state` lists it.
struct BotInfo: Identifiable, Hashable {
    let json: JSON
    var id: String { json["id"].string ?? "" }
    var name: String { json["name"].string ?? "" }
    var role: String { json["role"].string ?? "" }
    /// The Bot's own chat, current part.
    var sessionId: String { json["sessionId"].string ?? "" }
    /// Earlier parts of its own chat.
    var parts: [String] { json["parts"].array.compactMap(\.string) }
    var colorKey: String? { json["color"].string }
    /// Holds its greeting until the user picks a model (web: the model picker).
    var waiting: Bool { json["waiting"].bool ?? false }
    var instructions: String { json["instructions"].string ?? "" }
    /// The model it was given (`provider/model`); nil: none picked, it cannot run.
    var model: String? { json["model"].string }
    /// The model it last ran on, which differs while the chosen one is not served.
    var runningModel: String? { json["appliedModel"].string ?? model }
    /// Its thinking level; nil: the model's default.
    var effort: String? { json["effort"].string }
    /// Its permission preset; nil: DSH's default.
    var permission: String? { json["permission"].string }
    /// A picture of its own (a data URL), drawn instead of its initial.
    var avatarImage: String? { json["avatar"]["image"].string }
    /// Its last turn failed for a reason the user can fix (`{code, …}`).
    var blocked: JSON? { json["blocked"].nonNull }
    var pinned: Bool { json["pinned"].bool ?? false }
    var hidden: Bool { json["hidden"].bool ?? false }
    /// Capabilities given to it (names from the team's library).
    var capabilities: [String] { json["capabilities"].array.compactMap(\.string) }
    /// Its own working folder; nil: the team workspace.
    var workDir: String? { json["workDir"].string }
}

/// One group chat.
struct RoomInfo: Identifiable, Hashable {
    let json: JSON
    var id: String { json["id"].string ?? "" }
    var name: String { json["name"].string ?? "" }
    var members: [String] { json["members"].array.compactMap { $0.string ?? $0["id"].string } }
    /// The group's own Session, current part.
    var sessionId: String { json["sessionId"].string ?? "" }
    /// Every Session the group runs: its own earlier parts and the members' hidden ones.
    var sessions: [String] { json["parts"].array.compactMap(\.string) + json["ownParts"].array.compactMap(\.string) }
    /// The last line, `名字：内容` (the user's own lines bare).
    var preview: String? { json["preview"].string }
    /// Its own name rather than one made from the members'.
    var named: Bool { json["named"].bool ?? false }
    /// The member who takes plain messages first; nil: none.
    var admin: String? { json["admin"].string }
    /// `admin`: plain messages go to the admin, who calls on others; `everyone`: every member replies in turn.
    var mode: String { admin == nil ? "everyone" : json["mode"].string ?? "admin" }
    /// What every member reads before it speaks.
    var notice: String { json["notice"].string ?? "" }
    /// A preset all members work with here, over their own.
    var permission: String? { json["permission"].string }
    var pinned: Bool { json["pinned"].bool ?? false }
    var hidden: Bool { json["hidden"].bool ?? false }
}

/// The Bot feature: ds-bot's team behind native pages. The plugin's HTTP route
/// (`POST /api/bot` with `{endpoint, payload}`) answers `{ok, value}` or
/// `{ok:false, error}`; `GET /api/bot/feed` is a Server-Sent Events stream that says when
/// to read `state` again and carries each new entry of a Bot's own chat as it lands.
/// The app pins the plugin's version (`PluginPins`): these endpoints carry no version.
@MainActor
@Observable
final class BotModel {
    static let package = "ds-bot"

    enum Status: Equatable {
        /// Not known yet (the engine or the plugin list is still loading).
        case unknown
        case notInstalled
        /// Installed but switched off.
        case disabled
        /// Installed at a version the native pages were not built against.
        case wrongVersion(String)
        case ready
    }

    @ObservationIgnored private unowned let app: AppModel
    /// The `state` view (bots, rooms, questions…), replaced on each new revision.
    private(set) var team: JSON = .null
    /// What changes without a revision: `activity` (per Bot) and `work`.
    private(set) var activity: [String: JSON] = [:]
    private(set) var work: JSON = .null
    /// The other live fields: `connectors`, `capabilityStatuses`, `learning`, `memoryNews`, `imStatus`…
    private(set) var live: [String: JSON] = [:]
    private static let liveKeys = ["connectors", "capabilityStatuses", "learning", "learningSettled", "memoryNews", "memoryReviews", "imStatus", "imVia"]
    /// The route answered: the plugin is loaded in this engine.
    private(set) var reachable = false
    /// Replies being written, by Session: the text so far.
    private(set) var writing: [String: String] = [:]
    /// Bumped whenever the feed (re)connects: what it missed is read again.
    private(set) var feedGeneration = 0
    private(set) var installing = false
    var installError: String?
    /// The running rounds of the open group chat (`room-progress`): `{callId, replies, speaking}`.
    /// A round's call settles only once every member has spoken; these carry the replies so far.
    private(set) var rounds: [JSON] = []
    /// Open the scheduled tasks of the Bot or group whose chat asked (its ＋ tray).
    var scheduleRequest: BotComposer?
    /// Open a side question on the Bot whose chat asked (its ＋ tray).
    var sideChatRequest: String?
    /// Open the memory of the Bot whose chat asked (a "memory updated" line).
    var memoryRequest: String?
    /// Show the Bot pages (the root view consumes it).
    var openRequest: BotOpenRequest?
    /// Memory changes already shown and closed, by Bot or group: the time of the change.
    private(set) var seenMemoryNews: [String: Double] = [:]
    /// Approvals already announced, so each rings once.
    @ObservationIgnored private var announcedApprovals: Set<String> = []
    /// The chat on screen (a Bot's or a group's id): what waits there needs no announcement.
    var visibleChat: String?

    @ObservationIgnored private var revision: Double?
    @ObservationIgnored private var liveKey: String?
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var listeners: [UUID: (String, JSON) -> Void] = [:]

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Status

    var installedPackage: PluginPackage? {
        guard let package = app.plugins.package(Self.package), package.installed || package.availability != "missing" else { return nil }
        return package
    }

    var status: Status {
        if reachable {
            if let version = installedPackage?.version, let pinned = PluginPins.version(of: Self.package), version != pinned { return .wrongVersion(version) }
            return .ready
        }
        guard app.plugins.status == .ready else { return .unknown }
        guard let package = installedPackage else { return .notInstalled }
        if !package.enabled { return .disabled }
        if let version = package.version, let pinned = PluginPins.version(of: Self.package), version != pinned { return .wrongVersion(version) }
        // Enabled but not answering yet: loading, or restarting the engine.
        return .unknown
    }

    // MARK: Team

    var bots: [BotInfo] { team["bots"].array.map(BotInfo.init) }
    var rooms: [RoomInfo] { team["rooms"].array.map(RoomInfo.init) }
    var mainBotId: String? { team["mainBotId"].string }
    var mainBot: BotInfo? { bots.first { $0.id == mainBotId } ?? bots.first }
    func bot(_ id: String) -> BotInfo? { bots.first { $0.id == id } }
    /// The Bots that take the user's work first; the first is `mainBotId`.
    var mainBotIds: [String] { team["mainBotIds"].array.compactMap(\.string) }
    func isMain(_ bot: BotInfo) -> Bool { mainBotIds.contains(bot.id) }
    /// The models this DSH serves: `{ref, name, providerName, needsKey?}`.
    var models: [JSON] { team["models"].array }
    func modelName(_ ref: String?) -> String? {
        guard let ref else { return nil }
        return models.first { $0["ref"].string == ref }?["name"].string ?? ref
    }
    /// The name of the Bot's thinking level, from its model's levels when the team lists them.
    func effortName(of bot: BotInfo) -> String? {
        guard let effort = bot.effort else { return nil }
        let model = models.first { $0["ref"].string == bot.runningModel }
        return model?["reasoning"]["efforts"].array.first { $0["id"].string == effort }?["name"].string ?? effort
    }
    /// DSH's permission presets: `{value, name, description?}`; empty when this DSH has none.
    var permissionOptions: [JSON] { team["permissions"]["options"].array }
    var defaultPermission: String? { team["permissions"]["defaultPreset"].string }
    func permissionName(_ value: String?) -> String? {
        guard let value = value ?? defaultPermission else { return nil }
        return SettingsView.permissionName(permissionOptions.first { $0["value"].string == value } ?? ["value": .string(value)])
    }
    // MARK: Capabilities, connectors, secrets

    /// The team's library: `{name, kind:'mcp'|'skill'|'pack', description, transport?, url?, command?, approved?, items?, content?}`.
    var capabilities: [JSON] { team["capabilities"].array }
    /// A capability's state on a Bot: `ready`, `connecting`, `needs-approval` or `error` (with `error`).
    func capabilityStatus(_ name: String, of bot: BotInfo) -> JSON { live["capabilityStatuses"]?[bot.id][name] ?? .null }
    /// The connectors view: `{connectors:[Row], mail:{accounts, google, allowedRecipients, noDraftFor, pending?}}`.
    var connectors: [JSON] { live["connectors"]?["connectors"].array ?? [] }
    var mail: JSON { live["connectors"]?["mail"] ?? .null }
    func connector(_ id: String) -> JSON? { connectors.first { $0["id"].string == id } }
    /// `{name, purpose, scope:'all'|[botId], requestedBy, createdAt, updatedAt}`; values never leave the engine.
    var secrets: [JSON] { team["secrets"].array }
    /// A Bot's pending cards in its own chat.
    func secretRequests(of bot: BotInfo) -> [JSON] { team["secretRequests"][bot.id].array.filter { $0["status"].string == "pending" } }
    func connectorRequests(of bot: BotInfo) -> [JSON] { team["connectorRequests"][bot.id].array.filter { $0["status"].string == "pending" } }
    func mailRequests(of bot: BotInfo) -> [JSON] { team["mailRequests"][bot.id].array.filter { $0["status"].string == "pending" } }

    /// The connectors view comes back from every connector call; it is live data, so it is kept at once.
    func applyConnectors(_ value: JSON) {
        if value["connectors"].array.isEmpty && value["mail"].isNull { return }
        if live["connectors"] != value { live["connectors"] = value }
    }

    /// The plugin's colour names (`colors`).
    var colorKeys: [String] { team["colors"].array.compactMap(\.string) }
    func room(_ id: String) -> RoomInfo? { rooms.first { $0.id == id } }
    /// A group's name. One the user never named is the plugin's list of who is in it, in
    /// English (`You, A, B`); it is made here from the members instead.
    func name(of room: RoomInfo) -> String {
        guard !room.named else { return room.name }
        let members = room.members.compactMap { bot($0)?.name }
        guard !members.isEmpty else { return room.name }
        return ([String(localized: "你")] + members).joined(separator: String(localized: "、"))
    }

    /// The team's workspace: its sessions are the Bots' and the groups', shown here, not in the drawer.
    var teamWorkspaceId: String? { reachable ? team["workspaceId"].string : nil }

    /// Every Session the team runs; the drawer leaves them out.
    var teamSessionIds: Set<String> {
        guard reachable else { return [] }
        var ids = Set<String>()
        for bot in bots { ids.insert(bot.sessionId); ids.formUnion(bot.parts) }
        for room in rooms { ids.insert(room.sessionId); ids.formUnion(room.sessions) }
        ids.remove("")
        return ids
    }

    /// What a Bot is up to (`activity`): `working`, `thinking`, `alert` (it waits for the user
    /// to allow a tool), `waiting` (it handed work on and waits for it to come back).
    enum Doing: Equatable {
        case idle, working, approval
        /// The Bots and groups it waits on, by name.
        case waiting([String])
    }

    func doing(_ botId: String) -> Doing {
        switch activity[botId]?.string {
        case nil, "idle": return .idle
        case "alert": return .approval
        case "waiting":
            let entry = work["waiting"][botId]
            let names = entry["bots"].array.compactMap { $0.string.flatMap(bot)?.name }
                + entry["rooms"].array.compactMap { $0.string.flatMap(room).map(name(of:)) }
            return .waiting(names)
        default: return .working
        }
    }

    /// The Bot is working: in its own chat or in a group.
    func isWorking(_ botId: String) -> Bool { doing(botId) == .working }

    /// A line for what the Bot is up to; nil while it is idle.
    func doingText(_ botId: String) -> String? {
        switch doing(botId) {
        case .idle: nil
        case .working: workPhrase(botId) ?? String(localized: "在干活")
        case .approval: String(localized: "等你批准")
        case .waiting(let names): names.isEmpty ? String(localized: "在等别的 Bot 回复") : String(localized: "在等\(names.joined(separator: "、"))回复")
        }
    }

    /// What the running call does, in the Bot's own words (`work.bots[id]`), when it said so.
    func workPhrase(_ botId: String) -> String? {
        let entry = work["bots"][botId]
        let own = (entry["said"].string ?? entry["note"].string)?.trimmingCharacters(in: CharacterSet(charactersIn: " .。…\n"))
        return own?.isEmpty == false ? own : nil
    }

    /// What waits on the user for this Bot, anywhere: approvals, cards, a model to pick, a repair.
    func pendingCount(of bot: BotInfo) -> Int {
        var count = 0
        if bot.waiting { count += 1 } else if bot.blocked != nil { count += 1 }
        if question(of: bot) != nil { count += 1 }
        if pendingView(of: bot) != nil { count += 1 }
        count += secretRequests(of: bot).count + connectorRequests(of: bot).count + mailRequests(of: bot).count
        count += work["approvals"].array.filter { $0["botId"].string == bot.id }.count
        count += live["learning"]?[bot.id].array.count ?? 0
        return count
    }

    /// Another dsh holds the team: this one only reads it. The reason, in the plugin's words.
    var readOnly: String? { team["readOnly"].string }
    /// The window preferences ds-bot keeps for every client (`set-prefs`).
    var prefs: JSON { team["prefs"] }
    /// Reasoning shows in Bot chats only when the user asked for it (ds-bot's `thinking` preference).
    var showsThinking: Bool { prefs["thinking"].bool == true }
    /// Deleted private Bots whose folders stay closed to the others: `{id, name, workDir?}`.
    var privateArchives: [JSON] { team["privateArchives"].array }
    /// The latest memory change of a Bot or group the user has not seen: `{at, op, text}`.
    func memoryNews(_ id: String) -> JSON? {
        guard let news = live["memoryNews"]?[id].nonNull, let at = news["at"].double, at > (seenMemoryNews[id] ?? 0) else { return nil }
        return news
    }

    func dismissMemoryNews(_ id: String) {
        if let at = live["memoryNews"]?[id]["at"].double { seenMemoryNews[id] = at }
    }

    var workingCount: Int { bots.filter { isWorking($0.id) }.count }

    /// The turns of the Bot's own chat that answered another Bot: ds-bot's window leaves them out.
    func hiddenTurns(of bot: BotInfo) -> Set<Int> {
        Set(team["exchangeTurns"][bot.sessionId].array.compactMap(\.int))
    }

    /// The main Bot keeps the app's mascot while it has the plugin's default look (the whale).
    func usesAppMark(_ bot: BotInfo) -> Bool {
        let shape = bot.json["avatar"]["shape"].string
        return bot.id == mainBotId && (shape == nil || shape == "whale") && bot.json["avatar"]["image"].isNull
    }

    /// The card a Bot is waiting on, in its own chat: `{id, question, detail?, options:[{label, description?}], multiSelect}`.
    func question(of bot: BotInfo) -> JSON? { team["questions"][bot.sessionId].nonNull }

    /// A form the Bot sent that waits for an answer (`show_view`): `{id, title, view}`.
    func pendingView(of bot: BotInfo) -> JSON? { team["views"][bot.sessionId].nonNull }

    /// The plugin's colour names and the ink its own window paints them in (light appearance).
    static let inks: [String: String] = [
        "deepseek": "#4D6BFE", "charcoal": "#141416", "graphite": "#2D2D2D", "rose": "#EC2F6B", "sky": "#0AA8D6",
        "tangerine": "#FF6900", "cobalt": "#082DFF", "black": "#000000", "brown": "#9A6B44", "red": "#FF3E51",
        "orange": "#FF6B1A", "yellow": "#FFB020", "green": "#10B981", "cyan": "#06B6D4", "blue": "#2563EB",
        "violet": "#8B5CF6", "magenta": "#F43F85", "gray": "#8A8F98", "aurora": "#00B8D4",
    ]

    /// The Bot's display colour: one of the plugin's colour names, or a hex.
    func color(of bot: BotInfo) -> Color {
        if let key = bot.colorKey, let color = Color(hex: Self.inks[key] ?? key) { return color }
        let palette: [Color] = [Color(red: 0.18, green: 0.44, blue: 0.84), Color(red: 0.72, green: 0.38, blue: 0.04), Color(red: 0.48, green: 0.31, blue: 0.79), Color(red: 0.07, green: 0.55, blue: 0.40), Color(red: 0.80, green: 0.27, blue: 0.36)]
        let hash = bot.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[hash % palette.count]
    }

    // MARK: Calls

    struct Unreachable: LocalizedError {
        var errorDescription: String? { String(localized: "Bot 插件没有响应") }
    }

    /// One endpoint call; returns `value`, throws the plugin's error.
    @discardableResult
    func call(_ endpoint: String, _ payload: JSON = [:]) async throws -> JSON {
        let client = app.client
        var request = client.request(client.origin.appendingPathComponent("api/bot"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(["endpoint": .string(endpoint), "payload": payload] as JSON)
        let (data, response) = try await client.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let reply = try? JSONDecoder().decode(JSON.self, from: data), reply["ok"].bool != nil else {
            if status == 404 { throw Unreachable() }
            throw EngineError(code: "HTTP_\(status)", message: String(localized: "Bot 插件返回了无法解析的响应（HTTP \(status)）"), detail: .null)
        }
        if reply["ok"].bool == true { return reply["value"] }
        let error = reply["error"]
        throw EngineError(code: error["code"].string, message: error["message"].string.map(BotErrorText.text) ?? String(localized: "Bot 操作失败"), detail: error)
    }

    // MARK: Following

    /// Read the team and follow the feed for as long as the connection lives.
    func start() {
        guard followTask == nil else { return }
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.app.plugins.refresh(revision: self.app.revision("plugin-manager/changed"))
                await self.refreshState()
                if self.reachable {
                    do { try await self.followFeed() } catch {}
                }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(self.reachable ? 1 : 4))
            }
        }
    }

    /// Read `state` again now; calls in a burst share one read.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            refreshTask = nil
            await refreshState()
        }
    }

    func refreshState() async {
        var payload: [String: JSON] = ["locale": .string(AppLanguage.isChinese ? "zh-CN" : "en")]
        if let revision { payload["since"] = .number(revision) }
        if let liveKey { payload["live"] = .string(liveKey) }
        // The model list changes without a revision (a key added in 设置): its key rides along.
        if let key = team["modelsKey"].string { payload["models"] = .string(key) }
        do {
            let value = try await call("state", .object(payload))
            // Each write tells every view that reads it, so only a change is written.
            if !reachable { reachable = true }
            if value["unchanged"].bool != true, team != value { team = value }
            if !value["activity"].isNull, activity != value["activity"].object { activity = value["activity"].object }
            if !value["work"].isNull, work != value["work"] { work = value["work"]; announceApprovals() }
            for key in Self.liveKeys where !value[key].isNull && live[key] != value[key] { live[key] = value[key] }
            revision = value["revision"].double
            liveKey = value["liveKey"].string
        } catch is Unreachable {
            if reachable { reachable = false }
            revision = nil
            liveKey = nil
        } catch {
            // The engine is restarting or the connection dropped: the next pass reads again.
        }
    }

    /// `event: …` / `data: {…}` pairs until the stream ends. The data line follows its event line.
    private func followFeed() async throws {
        let client = app.client
        var request = client.request(client.origin.appendingPathComponent("api/bot/feed"))
        request.timeoutInterval = 120
        let (bytes, response) = try await client.session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        var event = ""
        for try await line in bytes.lines {
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let data = Data(line.dropFirst(5).utf8)
                let value = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
                handle(event, value)
                event = ""
            }
        }
    }

    private func handle(_ event: String, _ value: JSON) {
        switch event {
        case "hello":
            feedGeneration += 1
            writing = [:]
            refresh()
        case "revision", "live":
            refresh()
        case "message":
            guard let sessionId = value["sessionId"].string else { return }
            let item = value["item"]
            if item["kind"].string == "bot" { writing[sessionId] = nil }
            for listener in listeners.values { listener(sessionId, item) }
        case "stream":
            guard let sessionId = value["sessionId"].string else { return }
            switch value["phase"].string {
            case "start": writing[sessionId] = ""
            case "end": writing[sessionId] = nil
            default: if let text = value["text"].string { writing[sessionId, default: ""] += text }
            }
        default:
            break
        }
    }

    /// New entries of the Bots' own chats as the feed delivers them: `(sessionId, item)`.
    func addListener(_ handler: @escaping (String, JSON) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    func removeListener(_ id: UUID) { listeners[id] = nil }

    // MARK: Actions

    /// Send a message to a Bot's own chat.
    func send(_ text: String, to bot: BotInfo) async -> Bool {
        await app.perform { try await self.call("send", ["sessionId": .string(bot.sessionId), "text": .string(text)]) }
    }

    /// Stop what the Bot does in its own chat.
    func stop(_ bot: BotInfo) async {
        Haptics.firm()
        await app.perform { try await self.app.client.call("session/cancel", ["request": ["sessionId": .string(bot.sessionId)]]) }
    }

    func answer(_ question: JSON, of bot: BotInfo, selected: [String], custom: String = "") async -> Bool {
        var answer: [String: JSON] = ["selected": .array(selected.map(JSON.string))]
        if !custom.isEmpty { answer["custom"] = .string(custom) }
        let done = await app.perform {
            try await self.call("answer-question", [
                "sessionId": .string(bot.sessionId),
                "questionId": question["id"],
                "answer": .object(answer),
            ])
        }
        if done { refresh() }
        return done
    }

    func dismiss(_ question: JSON, of bot: BotInfo) async {
        await app.perform { try await self.call("dismiss-question", ["sessionId": .string(bot.sessionId)]) }
        refresh()
    }

    /// Follow a group chat's rounds while it is open: every second while one runs.
    func followRounds(of roomId: String) async {
        defer { if !rounds.isEmpty { rounds = [] } }
        while !Task.isCancelled {
            if let value = try? await call("room-progress", ["roomId": .string(roomId)]), value.array != rounds { rounds = value.array }
            try? await Task.sleep(for: .seconds(rounds.isEmpty ? 3 : 1))
        }
    }

    /// What a group's members wait on the user to allow (`work.approvals`):
    /// `{id, botId, tool, reason, detail:{text?, code?}, answerable}`.
    func approvals(inRoom roomId: String) -> [JSON] {
        work["approvals"].array.filter { $0["roomId"].string == roomId && $0["answerable"].bool != false }
    }

    func answerApproval(_ approval: JSON, allow: Bool) async {
        Haptics.tap()
        await run("approval-answer", ["id": approval["id"], "choice": .string(allow ? "allow" : "reject")])
    }

    func round(_ callId: String) -> JSON? { rounds.first { $0["callId"].string == callId } }
    var speaking: [String] { rounds.flatMap { $0["speaking"].array.compactMap(\.string) } }

    /// A tool call waits for the user where they are not looking: say so once.
    private func announceApprovals() {
        let pending = work["approvals"].array.filter { $0["answerable"].bool != false }
        let ids = Set(pending.compactMap { $0["id"].string })
        defer { announcedApprovals = ids }
        for approval in pending {
            guard let id = approval["id"].string, !announcedApprovals.contains(id), let botId = approval["botId"].string, let bot = bot(botId) else { continue }
            let roomId = approval["roomId"].string
            if visibleChat == (roomId ?? botId) { continue }
            let route: BotRoute = roomId.map { .room($0) } ?? .bot(botId)
            let place = roomId.flatMap(room).map(name(of:))
            let text = place.map { String(localized: "\(bot.name)在「\($0)」里等你批准") } ?? String(localized: "\(bot.name)等你批准")
            BotNotifier.announce(text, detail: approval["tool"].string ?? "", app: app) { [weak self] in
                self?.openRequest = BotOpenRequest(route: route)
            }
        }
    }

    /// Change the preferences ds-bot keeps for every window of the team.
    @discardableResult
    func setPrefs(_ patch: [String: JSON]) async -> Bool { await run("set-prefs", patch) }

    // MARK: Managing

    /// Change a Bot: only the given fields. The feed brings the new team; this reads it at once.
    @discardableResult
    func update(_ bot: BotInfo, _ patch: [String: JSON]) async -> Bool {
        var payload = patch
        payload["id"] = .string(bot.id)
        return await run("update-bot", payload)
    }

    @discardableResult
    func run(_ endpoint: String, _ payload: [String: JSON]) async -> Bool {
        do {
            let value = try await call(endpoint, .object(payload))
            if endpoint.hasPrefix("connector-") { applyConnectors(value) }
            await refreshState()
            return true
        } catch {
            app.showToast(error.localizedDescription, tone: .warning)
            return false
        }
    }

    /// Copy a Bot (its role, instructions, look and model). The plugin names the copy in
    /// English (`X copy`); it is renamed in the app's words, the next free one.
    func duplicate(_ bot: BotInfo) async -> Bool {
        do {
            let copy = try await call("duplicate-bot", ["id": .string(bot.id)])
            guard let id = copy["id"].string else { return true }
            for index in 1...9 {
                let name = index == 1 ? String(localized: "\(bot.name)的副本") : String(localized: "\(bot.name)的副本 \(index)")
                if (try? await call("update-bot", ["id": .string(id), "name": .string(name)])) != nil { break }
            }
            await refreshState()
            return true
        } catch {
            app.showToast(error.localizedDescription, tone: .warning)
            return false
        }
    }

    /// Pin a Bot or group to the top of the list, or hide it from the list.
    func setFlags(_ id: String, pinned: Bool? = nil, hidden: Bool? = nil) async {
        Haptics.select()
        var payload: [String: JSON] = ["id": .string(id)]
        if let pinned { payload["pinned"] = .bool(pinned) }
        if let hidden { payload["hidden"] = .bool(hidden) }
        await run("set-flags", payload)
    }

    /// Change a group chat; the plugin answers with what changed.
    @discardableResult
    func update(_ room: RoomInfo, _ patch: [String: JSON]) async -> Bool {
        var payload = patch
        payload["id"] = .string(room.id)
        return await run("update-room", payload)
    }

    /// Answer a form a Bot sent (`show_view`): `action` is the id of the part used.
    func reply(to view: JSON, of bot: BotInfo, action: String, values: JSON) async -> Bool {
        let done = await app.perform {
            try await self.call("view-reply", ["sessionId": .string(bot.id), "viewId": view["id"], "action": .string(action), "values": values])
        }
        if done { refresh() }
        return done
    }

    func dismissView(of bot: BotInfo) async {
        await app.perform { try await self.call("dismiss-view", ["sessionId": .string(bot.sessionId)]) }
        refresh()
    }

    /// Install the pinned plugin, switched on. The engine restarts itself when the change needs it.
    func install() async {
        guard !installing else { return }
        installing = true
        installError = nil
        defer { installing = false }
        do {
            let result = try await app.client.call("pluginManager/installBundle", [
                "spec": .string(Self.package),
                "options": ["enabled": true, "saveExact": true, "requestId": .string(UUID().uuidString.lowercased())],
            ])
            if result["application"].string == "failed" || result["application"].string == "cancelled" {
                let code = result["error"]["code"].string
                installError = managementText(code: code, diagnostic: result["error"]["diagnostic"].string, incompatible: result["error"]["incompatible"].array, installing: true)
                return
            }
        } catch {
            installError = error.localizedDescription
            return
        }
        await app.plugins.load()
        // The plugin starts with the engine's next load: wait until it answers.
        for _ in 0..<60 where !reachable {
            await refreshState()
            if reachable { break }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Switch an installed, switched-off plugin back on.
    func enable() async {
        guard let package = installedPackage else { return }
        installing = true
        defer { installing = false }
        await app.perform { try await self.app.client.call("pluginManager/setBundleEnabled", ["name": .string(package.name), "enabled": true]) }
        await app.plugins.load()
        for _ in 0..<30 where !reachable {
            await refreshState()
            if reachable { break }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

extension AppModel {
    /// The Bot feature for this connection.
    var botTeam: BotModel { sharedModel(&SharedModelKey.bots) { BotModel(app: self) } }
}

extension Color {
    /// `#rrggbb`.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
