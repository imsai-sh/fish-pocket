import Foundation

/// What Agents Anywhere tells its clients, read field by field: the server's payloads grow with
/// every runtime it adds, so nothing here fails on a shape it has not seen (as `JSON` is used for the engine).

enum RemoteTime {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(_ value: JSON) -> Date? {
        guard let text = value.string, !text.isEmpty else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

/// A computer signed in to the same account (the server calls it a connector).
struct RemoteDevice: Identifiable, Hashable {
    let id: String
    var name: String
    /// `desktop` for the Agents Anywhere desktop app, otherwise its command-line connector.
    var kind: String
    var os: String?
    var online: Bool
    var lastSeen: Date?

    init?(_ json: JSON) {
        guard let id = json["id"].string else { return nil }
        self.id = id
        name = json["name"].string ?? id
        kind = json["connectorKind"].string ?? ""
        os = json["deviceOs"].string
        online = json["status"].string == "online"
        lastSeen = RemoteTime.date(json["lastSeenAt"])
    }

    var symbol: String {
        switch os?.lowercased() {
        case "darwin", "macos", "mac": "laptopcomputer"
        case "linux": "server.rack"
        default: "desktopcomputer"
        }
    }
}

/// A folder on a device that sessions run in.
struct RemoteProject: Identifiable, Hashable {
    let id: String
    var deviceId: String
    var name: String
    var path: String
    var pinned: Bool
    var lastActivity: Date?

    init?(_ json: JSON) {
        guard let id = json["id"].string, let deviceId = json["connectorId"].string else { return nil }
        self.id = id
        self.deviceId = deviceId
        path = json["workspacePath"].string ?? ""
        name = json["name"].string ?? (path as NSString).lastPathComponent
        pinned = json["pinned"].bool ?? false
        lastActivity = RemoteTime.date(json["lastActivityAt"])
    }
}

/// An agent set up on a device: Codex, Claude Code, DeepSeek Harness…
struct RemoteAgent: Identifiable, Hashable {
    let id: String
    var deviceId: String
    /// `codex`, `claude`, `dsh`…
    var type: String
    var name: String
    var typeName: String
    var configured: Bool
    var active: Bool
    var available: Bool
    var status: String
    var reason: String?

    init?(_ json: JSON) {
        guard let id = json["runtimeId"].string, let deviceId = json["connectorId"].string else { return nil }
        self.id = id
        self.deviceId = deviceId
        type = json["runtimeType"].string ?? ""
        typeName = json["typeDisplayName"].string ?? type
        name = json["displayName"].string ?? json["name"].string ?? typeName
        configured = json["configured"].bool ?? false
        active = json["active"].bool ?? false
        available = json["available"].bool ?? false
        status = json["status"].string ?? "unknown"
        reason = json["reason"].string ?? json["error"]["message"].string
    }

    /// A new session can start on it right now.
    var ready: Bool { configured && active && available && status == "running" }

    var statusText: String {
        switch status {
        case "running": String(localized: "运行中")
        case "starting", "validating", "discovering": String(localized: "启动中")
        case "stopping": String(localized: "停止中")
        case "stopped": String(localized: "已停止")
        case "error": String(localized: "出错")
        case "unavailable": String(localized: "不可用")
        case "available": String(localized: "未启动")
        default: String(localized: "未知")
        }
    }
}

enum RemoteStatus: String {
    case idle, waiting, pending, running, stopping, blocked, error, disconnected, unknown
    case waitingApproval = "waiting_approval"

    init(_ json: JSON) { self = json.string.flatMap(RemoteStatus.init(rawValue:)) ?? .unknown }

    /// A turn is under way (or about to be).
    var busy: Bool { [.running, .pending, .waiting, .waitingApproval, .stopping, .blocked].contains(self) }
}

/// One session of the account's list.
struct RemoteSession: Identifiable, Hashable {
    let id: String
    var deviceId: String
    var projectId: String?
    var agentId: String
    var agentType: String
    var agentName: String?
    var agentTypeName: String?
    var title: String?
    var cwd: String?
    var status: RemoteStatus
    /// Messages can be sent from here; a session started in the agent's own client is read-only until taken over.
    var takeover: Bool
    var deviceOnline: Bool
    var pinned: Bool
    var archived: Bool
    var unread: Bool
    var lastReadSeq: Int
    var latestTurnEndSeq: Int
    var sortAt: Date
    var updatedSeq: Int

    init?(_ json: JSON) {
        guard let id = json["id"].string, let deviceId = json["connectorId"].string else { return nil }
        self.id = id
        self.deviceId = deviceId
        projectId = json["projectId"].string
        agentId = json["runtimeId"].string ?? json["runtime"].string ?? ""
        agentType = json["runtimeType"].string ?? json["runtime"].string ?? ""
        agentName = json["runtimeName"].string
        agentTypeName = json["runtimeTypeDisplayName"].string
        title = json["title"].string
        cwd = json["cwd"].string
        status = RemoteStatus(json["status"])
        takeover = json["takeover"].bool ?? false
        deviceOnline = json["connectorStatus"].string == "online"
        pinned = json["pinned"].bool ?? false
        archived = json["archived"].bool ?? false
        unread = json["unread"].bool ?? false
        lastReadSeq = json["lastReadSeq"].int ?? 0
        latestTurnEndSeq = json["latestTurnEndSeq"].int ?? 0
        sortAt = RemoteTime.date(json["sortAt"]) ?? RemoteTime.date(json["lastActivityAt"]) ?? RemoteTime.date(json["createdAt"]) ?? .distantPast
        updatedSeq = json["updatedSeq"].int ?? 0
    }

    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return String(localized: "新会话")
    }

    /// 「Codex」「Claude Code」「DSH」: the short tag on a row.
    var agentTag: String { RemoteAgentKind.tag(type: agentType, typeName: agentTypeName) }

    /// The name the user gave this agent, else its kind: what status lines call it.
    var agentLabel: String {
        for name in [agentName, agentTypeName] {
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return agentTag
    }

    /// Waiting on the user, working, or finished since it was last read; in that order.
    var waiting: Bool { status == .waitingApproval }
    var working: Bool { [.running, .waiting, .pending].contains(status) }
    var hasUnread: Bool { unread && status == .idle }
}

enum RemoteAgentKind {
    static func tag(type: String, typeName: String?) -> String {
        switch type.lowercased() {
        case "codex": "Codex"
        case "claude", "claude-code", "claude_code": "Claude Code"
        case "dsh": "DSH"
        default: typeName?.isEmpty == false ? typeName! : type
        }
    }
}

/// A record of a session's timeline: a message, a tool call, a marker…
struct RemoteItem: Identifiable, Hashable {
    let id: String
    let sessionId: String
    var turnId: String?
    /// `message`, `reasoning`, `tool`, `file_change`, `artifact`, `marker`, `system`, `turn.start`, `turn.end`…
    var type: String
    /// `pending`, `running`, `waiting_approval`, `done`, `failed`, `cancelled`, `interrupted`, `hidden`.
    var status: String
    var role: String?
    var content: JSON
    var source: JSON
    var orderSeq: Int
    var revision: Int
    var updatedSeq: Int
    var contentHash: String
    var createdAt: Date?
    var completedAt: Date?

    init?(_ json: JSON) {
        guard let id = json["id"].string, let sessionId = json["sessionId"].string else { return nil }
        self.id = id
        self.sessionId = sessionId
        turnId = json["turnId"].string
        type = json["type"].string ?? "unknown"
        status = json["status"].string ?? "unknown"
        role = json["role"].string
        content = json["content"].isNull ? .object([:]) : json["content"]
        source = json["source"].isNull ? .object([:]) : json["source"]
        updatedSeq = json["updatedSeq"].int ?? 0
        orderSeq = json["orderSeq"].int ?? updatedSeq
        revision = json["revision"].int ?? 1
        contentHash = json["contentHash"].string ?? ""
        createdAt = RemoteTime.date(json["createdAt"])
        completedAt = RemoteTime.date(json["completedAt"])
    }

    /// A version of an item is told by these alone; the content is not walked.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision && lhs.updatedSeq == rhs.updatedSeq
            && lhs.contentHash == rhs.contentHash && lhs.status == rhs.status && lhs.orderSeq == rhs.orderSeq
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(revision)
        hasher.combine(updatedSeq)
    }

    /// The server may replace this version with `other`.
    func yields(to other: RemoteItem) -> Bool {
        other.revision > revision || (other.revision == revision && other.updatedSeq >= updatedSeq)
    }

    var active: Bool { ["pending", "running", "waiting_approval"].contains(status) }
    var failed: Bool { status == "failed" }
    var stopped: Bool { ["cancelled", "interrupted"].contains(status) }
    /// What the content says it is, where the type alone does not.
    var kind: String { content["kind"].string ?? type }
    var isReasoning: Bool { type == "reasoning" || (type == "system" && content["kind"].string == "reasoning") }
}

/// What a session's agent can do right now, by the server's capability ids.
struct RemoteCapabilities: Hashable {
    private var allowed: Set<String> = []
    private var known: Set<String> = []
    private var reasons: [String: String] = [:]

    init() {}

    init(_ json: JSON) {
        for item in json["capabilities"].array {
            guard let id = item["capabilityId"].string else { continue }
            known.insert(id)
            if item["supported"].bool == true, item["available"].bool == true, item["allowed"].bool == true { allowed.insert(id) }
            if let reason = item["unavailableReason"].string, !reason.isEmpty { reasons[id] = reason }
        }
    }

    func allows(_ id: String) -> Bool { allowed.contains(id) }
    /// The agent has it at all, usable now or not.
    func offers(_ id: String) -> Bool { known.contains(id) }
    func reason(_ id: String) -> String? { reasons[id] }
}

/// The agent's side of a session: whether it is working, and what it runs on.
struct RemoteRuntimeState: Hashable {
    var status: RemoteStatus
    /// `model`, `permission`, `effort` → the selection id in force (nil: the agent's own default).
    var selections: [String: String?]
    var metadata: JSON
    var agentId: String
    var updatedSeq: Int

    init?(_ json: JSON) {
        guard json["sessionId"].string != nil else { return nil }
        status = RemoteStatus(json["status"])
        var selections: [String: String?] = [:]
        for (scope, value) in json["selections"].object {
            if let id = value.string { selections[scope] = id } else if value.isNull { selections[scope] = .some(nil) }
        }
        self.selections = selections
        metadata = json["metadata"]
        agentId = json["runtimeId"].string ?? json["runtime"].string ?? ""
        updatedSeq = json["updatedSeq"].int ?? 0
    }
}

/// Something the agent tells or asks the user outside the timeline: an approval, a question, a form, a note.
struct RemoteNotice: Identifiable, Hashable {
    struct Action: Identifiable, Hashable {
        let id: String
        var label: String
        var style: String?
        var required: Bool
        var schema: JSON
        var uiSchema: JSON

        init?(_ json: JSON) {
            guard let id = json["actionId"].string else { return nil }
            self.id = id
            label = json["label"].string ?? id
            style = json["style"].string
            required = json["input"]["required"].bool ?? false
            schema = json["input"]["schema"]
            uiSchema = json["input"]["uiSchema"]
        }
    }

    let id: String
    let sessionId: String
    /// `interaction` waits for an answer; `notification` only informs.
    var type: String
    var title: String
    var message: String?
    var severity: String
    /// `open`, `responding`, `response_accepted`, `resolving`, `resolved`, `closed`, `expired`, `cancelled`, `failed`.
    var status: String
    /// `approval`, `input_request`, `confirmation`, `execution_error`…
    var interaction: String?
    var blocksSession: Bool
    var actions: [Action]
    var context: JSON
    var metadata: JSON
    var source: JSON
    var expiresAt: Date?
    var revision: Int

    init?(_ json: JSON) {
        guard let id = json["noticeId"].string, let sessionId = json["sessionId"].string else { return nil }
        self.id = id
        self.sessionId = sessionId
        type = json["type"].string ?? ""
        title = json["title"].string ?? ""
        message = json["message"].string
        severity = json["severity"].string ?? "info"
        status = json["status"].string ?? "unknown"
        interaction = json["interactionType"].string
        blocksSession = json["blocking"]["scope"].string == "session" && json["blocking"]["targetId"].string == sessionId
        actions = json["actions"].array.compactMap(Action.init)
        context = json["context"]
        metadata = json["metadata"]
        source = json["source"]
        expiresAt = RemoteTime.date(json["expiresAt"])
        revision = json["revision"].int ?? 1
    }

    /// Still on screen: an interaction until it is settled, a notification while open.
    var visible: Bool {
        if type == "notification" { return status == "open" }
        return type == "interaction" && ["open", "failed", "responding", "response_accepted", "resolving"].contains(status)
    }

    /// The user can still answer it.
    var answerable: Bool {
        type == "interaction" && ["open", "failed"].contains(status) && !(expiresAt.map { $0 <= .now } ?? false)
    }

    var isApproval: Bool { interaction == "approval" }
    /// The timeline record it is about (the tool call waiting to run).
    var targetItemId: String? { source["timelineItemId"].string ?? context["timelineItemId"].string }
    var failure: String? {
        status == "failed" ? context["error"]["message"].string ?? context["error"].string : nil
    }
}

/// A choice in a model or permission menu. Only `selectionId` goes back to the server.
struct RemoteOption: Identifiable, Hashable {
    let id: String
    var name: String
    var detail: String?
    var selectionId: String?
    var isDefault: Bool
    var enabled: Bool

    init?(_ json: JSON) {
        guard let id = json["id"].string else { return nil }
        self.id = id
        name = json["displayName"].string ?? id
        detail = json["description"].string
        selectionId = json["selectionId"].string
        isDefault = json["default"].bool ?? false
        enabled = json["enabled"].bool ?? json["metadata"]["enabled"].bool ?? true
    }
}

struct RemoteModelOption: Identifiable, Hashable {
    var option: RemoteOption
    /// The provider it goes through, where the agent has several.
    var group: String?
    var efforts: [RemoteOption]
    var id: String { option.id }

    init?(_ json: JSON) {
        guard let option = RemoteOption(json) else { return nil }
        self.option = option
        group = json["group"]["displayName"].string
        if let name = json["group"]["itemDisplayName"].string, !name.isEmpty { self.option.name = name }
        efforts = json["reasoningItems"].array.compactMap(RemoteOption.init)
    }

    /// What picking this model sends: its default level's id where it has levels.
    func selection(effort: String? = nil) -> String? {
        let level = efforts.first { $0.id == effort && $0.enabled } ?? efforts.first { $0.isDefault && $0.enabled } ?? efforts.first { $0.enabled }
        return level?.selectionId ?? option.selectionId
    }
}

struct RemoteCatalog: Hashable {
    var models: [RemoteModelOption] = []
    var permissions: [RemoteOption] = []

    /// The model (and its level) a `model` selection id stands for.
    func model(for selection: String?) -> (model: RemoteModelOption, effort: RemoteOption?)? {
        guard let selection else { return nil }
        for model in models {
            if let effort = model.efforts.first(where: { $0.selectionId == selection }) { return (model, effort) }
            if model.option.selectionId == selection { return (model, nil) }
        }
        return nil
    }
}

/// A slash command the agent offers.
struct RemoteCommand: Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String?
    var aliases: [String]
    var enabled: Bool
    var disabledReason: String?
    var takesArguments: Bool
    /// One free-form argument, not words.
    var wholeArgument: Bool
    var hint: String?
    /// Opens a menu (model, permission) instead of running.
    var selector: String?
    var multiline: Bool
    /// Statuses it may run in; nil: only while the agent is idle.
    var statuses: [String]?

    init?(_ json: JSON) {
        guard let id = json["id"].string else { return nil }
        self.id = id
        title = json["title"].string ?? id
        detail = json["description"].string
        aliases = json["aliases"].array.compactMap(\.string)
        enabled = json["enabled"].bool ?? true
        disabledReason = json["disabledReason"].string
        takesArguments = json["acceptsArgs"].bool ?? false
        wholeArgument = json["argsSchema"]["type"].string == "string"
        let ui = json["metadata"]["ui"]
        hint = ui["argumentHint"].string
        selector = ui["kind"].string == "selector" ? ui["target"].string : nil
        multiline = ui["acceptsMultiline"].bool ?? false
        statuses = ui["allowedStatuses"].isNull ? nil : ui["allowedStatuses"].array.compactMap(\.string)
    }

    func matches(_ query: String) -> Bool {
        let query = query.lowercased()
        return query.isEmpty || ([id, title] + aliases).contains { $0.lowercased().hasPrefix(query) }
    }

    func runs(in status: RemoteStatus) -> Bool {
        if let statuses { return statuses.contains(status.rawValue) }
        return status == .idle || status == .error
    }
}

/// A plan the agent wrote and is waiting to have approved (its native plan mode).
struct RemotePlan: Hashable, Identifiable {
    var reviewId: String
    var planId: String
    var revision: Int
    var contentHash: String
    var title: String
    var markdown: String
    var epoch: String
    var id: String { reviewId }

    /// Only a plan whose review is open, or whose approved run failed to start and may be retried.
    init?(_ json: JSON) {
        let review = json["review"], plan = json["proposal"]
        guard let reviewId = review["reviewId"].string, let planId = plan["planId"].string,
              review["planId"].string == planId, review["planRevision"].int == plan["revision"].int,
              review["contentHash"].string == plan["contentHash"].string else { return nil }
        let retry = review["status"].string == "approved" && json["execution"]["status"].string == "rejected" && json["execution"]["retryable"].bool == true
        guard review["status"].string == "open" || retry else { return nil }
        let actions = json["capabilities"]["actions"].array.compactMap(\.string)
        guard actions.contains(where: { ["approve_and_execute", "request_revision", "dismiss_review"].contains($0) }) else { return nil }
        self.reviewId = reviewId
        self.planId = planId
        revision = plan["revision"].int ?? 0
        contentHash = plan["contentHash"].string ?? ""
        title = plan["title"].string ?? ""
        markdown = plan["markdown"].string ?? ""
        epoch = json["epoch"].string ?? ""
    }
}

/// An entry of a folder on a device.
struct RemoteFileEntry: Identifiable, Hashable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int?
    var id: String { path }

    init?(_ json: JSON) {
        guard let path = json["path"].string else { return nil }
        self.path = path
        name = json["name"].string ?? (path as NSString).lastPathComponent
        isDirectory = json["type"].string == "directory"
        size = json["size"].int
    }
}

/// A message sent from here that the timeline has not echoed yet.
struct RemotePendingMessage: Identifiable, Hashable {
    enum Delivery: Hashable { case sending, accepted, failed(String), uncertain(String) }
    let id: String
    var text: String
    var attachments: [RemoteUpload]
    var delivery = Delivery.sending
    var sentAt = Date()
}
