import Foundation
import Observation

/// A draft that starts with `/`: the command it names and what follows.
struct RemoteSlash {
    let command: String
    let rest: String
    let multiline: Bool

    init?(_ raw: String) {
        let trimmed = raw.drop { $0.isWhitespace }
        guard trimmed.first == "/" else { return nil }
        let body = trimmed.dropFirst()
        let token = body.prefix { !$0.isWhitespace }
        command = token.lowercased()
        rest = String(body.dropFirst(token.count))
        multiline = raw.contains { $0.isNewline }
    }

    /// A token that could name a command; `/Users/me` never does.
    var commandLike: Bool {
        guard let first = command.unicodeScalars.first else { return true }
        let body = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_:.-")
        let leading = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        return leading.contains(first) && command.unicodeScalars.allSatisfy(body.contains)
    }
}

/// One remote session while it is open: its timeline, what its agent is doing and asking, and
/// the things the user can do to it. The durable part (records, metadata) comes as a snapshot and
/// then as numbered events over a WebSocket; a gap or a reconnect is filled from the server's
/// event log. The live part (status, capabilities, pending requests) is re-read whenever the
/// channel is re-established, and counts as current only while the channel is up.
@MainActor
@Observable
final class RemoteSessionModel: Identifiable {
    enum Link: Equatable { case connecting, live, reconnecting, failed(String) }

    let id: String
    private(set) var meta: RemoteSession?
    private(set) var rows: [RemoteRow] = []
    private(set) var hasOlder = false
    private(set) var loadingOlder = false
    private(set) var loaded = false
    private(set) var link = Link.connecting
    private(set) var state: RemoteRuntimeState?
    private(set) var capabilities = RemoteCapabilities()
    private(set) var notices: [RemoteNotice] = []
    private(set) var plan: RemotePlan?
    private(set) var catalog: RemoteCatalog?
    private(set) var commands: [RemoteCommand] = []
    private(set) var pending: [RemotePendingMessage] = []
    /// A send, stop, takeover or answer is on its way.
    private(set) var working = false
    /// Requests answered from here that the agent has not settled yet.
    private(set) var answering: Set<String> = []
    /// Bumped when a command asks for the model and permission menu.
    private(set) var optionsRequest = 0
    /// Status, capabilities and requests were read since the channel last came up. Observed:
    /// what can be sent or answered follows it.
    private var fresh = false
    /// The channel has been down for longer than a moment. A short drop (the app back in
    /// front, a network change, the server closing an idle socket) reconnects without a word:
    /// only one that lasts is said, in the title and the composer.
    private(set) var struggling = false
    var error: String?
    /// Something to mention in passing (a toast), not a failure to stop for.
    var notice: String?
    var draft = ""
    var attachments: [RemoteUpload] = []

    @ObservationIgnored private weak var store: RemoteStore?
    @ObservationIgnored private var items: [RemoteItem] = []
    @ObservationIgnored private var builder = RemoteTimelineBuilder()
    @ObservationIgnored private var cursor = "seq:0"
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var seenOrder: [String] = []
    @ObservationIgnored private var run: Task<Void, Never>?
    /// Live facts were read at this time; frames that arrived earlier are older than them.
    @ObservationIgnored private var barrier = 0.0
    @ObservationIgnored private var rebuildQueued = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var patience: Task<Void, Never>?

    /// How long the channel may be down before the page says so.
    private static let quietReconnect = Duration.seconds(5)

    private static let windowLimit = 1000
    /// What a session keeps once its page has closed: enough to show at once when it is opened
    /// again. Whatever the reader paged back to is let go, and read again if they go back.
    private static let parkedLimit = 200
    private static let liveKinds: Set<String> = ["session.meta.updated", "runtime.state.updated", "runtime.capability.updated", "runtime.catalog.updated"]
    private static let readKinds: Set<String> = ["runtime.state.updated", "runtime.capability.updated", "runtime.notice.snapshot", "runtime.notice.updated"]

    init(id: String, store: RemoteStore) {
        self.id = id
        self.store = store
        meta = store.sessions[id]
    }

    private var path: String { "/sessions/\(RemoteClient.encode(id))" }
    private var client: RemoteClient? { store?.client }

    // MARK: What the page reads

    /// Status, capabilities and requests are current.
    var current: Bool { link == .live && fresh }
    var online: Bool { meta?.deviceOnline ?? false }
    var status: RemoteStatus { (current ? state?.status : nil) ?? meta?.status ?? .unknown }
    var busy: Bool { online && status.busy }
    var takeover: Bool { meta?.takeover ?? false }
    var cwd: String? { meta?.cwd }

    /// Requests waiting for an answer, approvals first.
    var interactions: [RemoteNotice] {
        notices.filter { $0.type == "interaction" && $0.visible }.sorted { ($0.isApproval ? 0 : 1) < ($1.isApproval ? 0 : 1) }
    }

    /// Notes the agent left that need no answer.
    var notifications: [RemoteNotice] { notices.filter { $0.type == "notification" && $0.visible } }

    /// A message goes as a new turn, or into the running one where the agent only takes those.
    private var steers: Bool { busy && !capabilities.allows("session.send_message") && capabilities.allows("session.steer") }
    var canSend: Bool {
        current && (capabilities.allows("session.send_message") || steers) && !interactions.contains(where: \.blocksSession)
    }
    /// The channel is coming back and a message could be sent a moment ago. Sending is taken
    /// and waits for it, rather than being refused over a drop the user was never told about.
    var sendWaits: Bool {
        guard loaded, online, takeover, !current, !struggling else { return false }
        if case .failed = link { return false }
        return capabilities.allows("session.send_message") && !interactions.contains(where: \.blocksSession)
    }
    var canAttach: Bool { capabilities.allows("runtime.attachment") }
    /// Approvals can be answered from here (an agent that says nothing about it is taken to allow it).
    var canApprove: Bool { !capabilities.offers("session.interaction.approval") || capabilities.allows("session.interaction.approval") }
    var canInterrupt: Bool { current && busy && (capabilities.allows("session.interrupt") || !capabilities.offers("session.interrupt")) }
    var canChoose: Bool { current && (capabilities.allows("catalog.model") || capabilities.allows("catalog.permission")) }
    var canCommand: Bool { current && capabilities.allows("session.commands") }
    var canToggleTakeover: Bool { link == .live && online && !working }

    /// Why nothing can be sent right now; nil when the composer is open.
    var sendBlock: String? {
        if case .failed(let message) = link { return message }
        if !loaded { return nil }
        if !online { return String(localized: "电脑离线，只能查看历史") }
        if !takeover { return String(localized: "这个会话在电脑上进行，接管后才能从这里发消息") }
        // Connecting, or reading the agent's state again: the composer stays and takes what is
        // typed, only sending waits; the title says what is going on. What follows judges by
        // facts that are current.
        guard current else { return nil }
        // While the agent works the composer stays, whatever can be sent: stopping it is there.
        if busy { return nil }
        if interactions.contains(where: \.blocksSession) { return String(localized: "先回应智能体的请求") }
        if !capabilities.allows("session.send_message") { return unavailableText }
        return nil
    }

    /// Why the agent takes no message, in words: its instance on the computer is not up, the
    /// kind of agent cannot, or what it said itself. A bare code says nothing to a reader.
    private var unavailableText: String {
        if let meta, let agent = store?.agents.first(where: { $0.id == meta.agentId }), !agent.ready {
            return String(localized: "电脑上的 \(agent.name) 还没就绪（\(agent.statusText)），请在电脑上的 Agents Anywhere 里看一下")
        }
        let reason = capabilities.reason("session.send_message") ?? ""
        switch reason {
        case "runtime_capability_unsupported": return String(localized: "这种智能体的会话不能从这里发消息")
        case "runtime_capability_unavailable", "": return String(localized: "电脑上的智能体现在收不了消息，可能还在启动。稍后点右上角的「重新同步」再试")
        case "connector_offline": return String(localized: "电脑离线，只能查看历史")
        case "session_not_taken_over": return String(localized: "这个会话在电脑上进行，接管后才能从这里发消息")
        default:
            let readable = reason.contains(" ") || reason.unicodeScalars.contains { $0.value > 0x2E80 }
            return readable ? reason : String(localized: "电脑上的智能体现在收不了消息，可能还在启动。稍后点右上角的「重新同步」再试")
        }
    }

    /// The model and permission in force, as the option menu names them.
    var modelLabel: String? {
        guard let selection = state?.selections["model"] ?? nil, let found = catalog?.model(for: selection) else { return nil }
        return [found.model.option.name, found.effort?.name].compactMap { $0 }.joined(separator: " · ")
    }

    var permissionLabel: String? {
        guard let selection = state?.selections["permission"] ?? nil else { return nil }
        return catalog?.permissions.first { $0.selectionId == selection }?.name
    }

    /// Every block of the loaded turns, for the list of changed files.
    var blocks: [AssistantBlock] {
        rows.flatMap { row -> [AssistantBlock] in
            if case .turn(let turn) = row { return turn.blocks }
            return []
        }
    }

    func toolCall(_ id: String) -> ToolCall? {
        for case .tool(let call) in blocks.reversed() where call.id == id { return call }
        return nil
    }

    func reasoning(_ id: String) -> String? {
        for case .reasoning(id, let text) in blocks.reversed() { return text }
        return nil
    }

    // MARK: Connection

    func start() {
        guard run == nil, !suspended, let store, let client = store.client else { return }
        run = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    if self.link != .live { self.link = self.loaded ? .reconnecting : .connecting }
                    self.worry()
                    if !self.loaded { try await self.loadSnapshot(client) }
                    let ticket = try await client.ticket(sessionId: self.id)
                    for try await frame in client.frames("\(self.path)/ws", ticket: ticket) {
                        if frame["type"].string == "session.subscribed" {
                            // Subscribed before reading: nothing falls between the read and the stream.
                            try await self.reconcile(client)
                            self.link = .live
                            self.calm()
                            attempt = 0
                        } else {
                            try await self.receive(frame, client)
                        }
                    }
                    throw RemoteError(kind: .server, message: String(localized: "与服务器的连接中断"))
                } catch {
                    guard !Task.isCancelled else { return }
                    let failure = RemoteError(error)
                    self.fresh = false
                    guard failure.transient else {
                        self.calm()
                        if failure.kind != .cancelled { self.link = .failed(failure.message) }
                        self.run = nil
                        return
                    }
                    self.link = .reconnecting
                    self.worry()
                    attempt += 1
                    try? await Task.sleep(for: .seconds(min(pow(2, Double(attempt - 1)), 15)))
                }
            }
        }
    }

    private func stop() {
        run?.cancel()
        run = nil
        fresh = false
        calm()
    }

    /// The channel is not up: it is said only if that lasts.
    private func worry() {
        guard patience == nil, !struggling, link != .live else { return }
        patience = Task { [weak self] in
            try? await Task.sleep(for: Self.quietReconnect)
            guard !Task.isCancelled, let self else { return }
            self.patience = nil
            if self.link != .live { self.struggling = true }
        }
    }

    private func calm() {
        patience?.cancel()
        patience = nil
        if struggling { struggling = false }
    }

    /// The session is no longer kept, or the account went.
    func close() {
        stop()
    }

    /// The page went away: the channel closes and only the recent end of the timeline stays,
    /// so that a kept session costs a bounded amount of memory however far back it was read.
    func park() {
        suspend()
        guard items.count > Self.parkedLimit else { return }
        items.removeFirst(items.count - Self.parkedLimit)
        hasOlder = true
        rebuild()
    }

    /// The app left the front: the channel closes, what was read stays on screen.
    func suspend() {
        suspended = true
        stop()
        if link == .live { link = .reconnecting }
    }

    func resume() {
        suspended = false
        start()
    }

    /// Read everything again (pull to refresh, or after a failure).
    func refresh() async {
        guard let client else { return }
        stop()
        answering = []
        if online { _ = try? await client.post("\(path)/sync") }
        loaded = false
        link = .connecting
        start()
    }

    private func loadSnapshot(_ client: RemoteClient) async throws {
        let value = try await client.get("\(path)/snapshot", query: ["limit": "100"])
        guard value["session"]["id"].string == id else {
            throw RemoteError(kind: .invalid, message: String(localized: "服务器返回了无法识别的内容"))
        }
        store?.upsert(value["session"])
        meta = RemoteSession(value["session"]) ?? meta
        items = []
        hasOlder = value["timeline"]["hasMore"].bool ?? false
        merge(value["timeline"]["items"].array.compactMap(RemoteItem.init), history: false)
        state = RemoteRuntimeState(value["state"])
        capabilities = RemoteCapabilities(value["effectiveCapabilities"])
        notices = value["notices"].array.compactMap(RemoteNotice.init)
        cursor = value["eventCursor"].string ?? "seq:0"
        seen = []
        seenOrder = []
        catalog = nil
        loaded = true
        rebuild()
    }

    private func sequence(_ cursor: String) -> Int { Int(cursor.dropFirst(4)) ?? 0 }

    private func advance(_ next: String?) {
        if let next, sequence(next) > sequence(cursor) { cursor = next }
    }

    private func receive(_ frame: JSON, _ client: RemoteClient) async throws {
        guard frame["sessionId"].string == id else { return }
        let type = frame["type"].string ?? ""
        switch type {
        case "planning.state.updated":
            plan = RemotePlan(frame["payload"]["state"])
            return
        case "goal.state.updated":
            return
        default:
            break
        }
        if type == "session.refetch_required" || (frame["sequence"].int ?? 0) > sequence(cursor) + 1 {
            try await reconcile(client)
        }
        if Self.readKinds.contains(type), (frame[RemoteClient.arrival].double ?? .infinity) < barrier { return }
        let wasOnline = online
        apply(frame)
        queueRebuild()
        if online, !wasOnline { try await reconcile(client) }
    }

    private func apply(_ event: JSON) {
        guard event["sessionId"].string == id, (event["sequence"].int ?? 0) >= sequence(cursor) else { return }
        let type = event["type"].string ?? ""
        let durable = !Self.liveKinds.contains(type)
        let eventId = event["eventId"].string ?? ""
        if durable, seen.contains(eventId) { return }
        let payload = event["payload"]
        switch type {
        case "session.meta.updated":
            store?.upsert(payload["session"])
            if let next = RemoteSession(payload["session"]) { adopt(next) }
        case "runtime.state.updated":
            if let next = RemoteRuntimeState(payload["state"]), next.agentId == (meta?.agentId ?? next.agentId),
               next.updatedSeq >= (state?.updatedSeq ?? 0) { state = next }
        case "runtime.capability.updated":
            capabilities = RemoteCapabilities(payload["capabilitySet"])
        case "timeline.item_created", "timeline.item_updated":
            if let item = RemoteItem(payload["item"]) { merge([item], history: false) }
        case "timeline.snapshot":
            items = []
            hasOlder = false
            merge(payload["items"].array.compactMap(RemoteItem.init), history: false)
        case "runtime.notice.snapshot":
            notices = payload["notices"].array.compactMap(RemoteNotice.init)
            settleAnswers()
        case "runtime.notice.updated":
            guard let notice = RemoteNotice(payload["notice"]), notice.sessionId == id else { break }
            if let index = notices.firstIndex(where: { $0.id == notice.id }) {
                if notice.revision >= notices[index].revision { notices[index] = notice }
            } else {
                notices.append(notice)
            }
            settleAnswers()
        case "runtime.catalog.updated":
            catalog = nil
            commands = []
        case "session.subscribed", "session.refetch_required":
            return
        default:
            break
        }
        advance(event["cursor"].string)
        if durable, !eventId.isEmpty {
            seen.insert(eventId)
            seenOrder.append(eventId)
            if seenOrder.count > 2048 { seen.remove(seenOrder.removeFirst()) }
        }
    }

    /// Fill in what the channel may have missed, then re-read the live facts.
    private func reconcile(_ client: RemoteClient) async throws {
        let value = try await client.get("\(path)/events", query: ["after": cursor])
        if value["snapshotRequired"].bool == true {
            try await loadSnapshot(client)
        } else {
            for event in value["events"].array.sorted(by: { ($0["sequence"].int ?? 0) < ($1["sequence"].int ?? 0) }) { apply(event) }
            advance(value["nextCursor"].string)
        }
        // What was read before holds while it is read again: a gap in the channel's numbering
        // (the server folds and skips events, so they are common) must not take the composer
        // away for the time of a few requests. A lost channel or an offline computer does.
        if !online { fresh = false }
        if online {
            let started = Date().timeIntervalSince1970
            async let stateValue = client.get("\(path)/runtime/state")
            async let capabilityValue = client.get("\(path)/runtime/capabilities")
            async let noticeValue = client.get("\(path)/runtime/notices")
            let (liveState, liveCapabilities, liveNotices) = try await (stateValue, capabilityValue, noticeValue)
            if let next = RemoteRuntimeState(liveState["state"]) { state = next }
            capabilities = RemoteCapabilities(liveCapabilities["capabilitySet"])
            notices = liveNotices["notices"].array.compactMap(RemoteNotice.init)
            barrier = started
            fresh = true
            settleAnswers()
            if capabilities.allows("session.plan_review"), let value = try? await client.get("\(path)/planning") {
                plan = RemotePlan(value)
            } else {
                plan = nil
            }
        }
        rebuild()
    }

    /// The list's own reading of this session (it follows every session of the account).
    func apply(meta next: RemoteSession) {
        guard next.updatedSeq >= (meta?.updatedSeq ?? 0), next != meta else { return }
        let cameOnline = next.deviceOnline && !online
        adopt(next)
        queueRebuild()
        // The device is back: the channel has to be read again from its side.
        if cameOnline, run != nil {
            stop()
            start()
        }
    }

    private func adopt(_ next: RemoteSession) {
        let changedAgent = meta.map { $0.agentId != next.agentId } ?? false
        meta = next
        if !next.deviceOnline || changedAgent {
            fresh = false
            catalog = nil
            commands = []
        }
    }

    private func settleAnswers() {
        // Still open on the server: the answer is on its way. Anything else is the agent's own word.
        answering.formIntersection(notices.filter { $0.status == "open" }.map(\.id))
    }

    // MARK: Records

    private func merge(_ incoming: [RemoteItem], history: Bool) {
        let start = items.first?.orderSeq ?? 0
        for item in incoming where item.sessionId == id {
            if let index = items.lastIndex(where: { $0.id == item.id }) {
                guard items[index].yields(to: item) else { continue }
                if items[index].orderSeq == item.orderSeq { items[index] = item; continue }
                items.remove(at: index)
            } else if !history, hasOlder, item.orderSeq < start {
                continue // Recovery must not bring back rows from before the loaded window.
            }
            items.insert(item, at: position(of: item))
        }
        // Only the live end is bounded: what the reader paged back to stays.
        if !history, items.count > Self.windowLimit {
            items.removeFirst(items.count - Self.windowLimit)
            hasOlder = true
        }
    }

    private func position(of item: RemoteItem) -> Int {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if (items[mid].orderSeq, items[mid].id) < (item.orderSeq, item.id) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Streamed frames come in bursts: the rows are rebuilt once per pass of the main queue.
    private func queueRebuild() {
        guard !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.rebuildQueued = false
            self?.rebuild()
        }
    }

    private func rebuild() {
        let echoed = RemoteTimelineBuilder.echoed(items)
        let users = items.filter { $0.role == "user" && $0.type == "message" }
        pending.removeAll { message in
            if echoed.contains(message.id) { return true }
            // An agent that does not echo the id: the same words, written after they were sent.
            guard message.delivery == .accepted else { return false }
            return users.contains { ($0.createdAt ?? .distantPast) > message.sentAt.addingTimeInterval(-5)
                && ($0.content["text"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == message.text }
        }
        let next = builder.rows(items: items, busy: busy, pending: pending)
        if next != rows { rows = next }
    }

    func loadOlder() async {
        guard hasOlder, !loadingOlder, let client, let before = items.first?.orderSeq else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let value = try await client.get("\(path)/timeline", query: ["mode": "history", "beforeOrderSeq": String(before), "limit": "100"])
            guard value["sessionId"].string == id else { return }
            merge(value["items"].array.compactMap(RemoteItem.init), history: true)
            hasOlder = value["hasMore"].bool ?? false
            rebuild()
        } catch {
            report(error)
        }
    }

    // MARK: Actions

    private func report(_ failure: Error) {
        let failure = RemoteError(failure)
        if failure.kind != .cancelled { error = failure.message }
    }

    /// `{ok, result: {ok}?, error?}`: the server took it and the agent did not refuse it.
    private func accepted(_ value: JSON) throws {
        guard value["ok"].bool != false, value["result"]["ok"].bool != false else {
            throw RemoteError(kind: .rejected, code: value["error"]["code"].string,
                              message: value["error"]["message"].string ?? String(localized: "智能体没有接受这次操作"))
        }
    }

    private func act(_ work: (RemoteClient) async throws -> Void) async -> Bool {
        guard !working, let client else { return false }
        working = true
        defer { working = false }
        do { try await work(client); return true } catch { report(error); return false }
    }

    /// Send the draft: a slash command the agent offers runs as one, anything else is a message.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !text.isEmpty || !files.isEmpty, let client else { return }
        if files.isEmpty, let slash = RemoteSlash(text), slash.commandLike, !slash.command.isEmpty, canCommand {
            if commands.isEmpty { await loadCommands() }
            if let command = commands.first(where: { ([$0.id] + $0.aliases).contains { $0.lowercased() == slash.command } }) {
                await run(command, slash: slash, raw: text)
                return
            }
        }
        let waits = !canSend && sendWaits
        guard canSend || waits else { error = sendBlock ?? String(localized: "这个会话暂时不能接收消息"); return }
        let message = RemotePendingMessage(id: UUID().uuidString, text: text, attachments: files)
        pending.append(message)
        draft = ""
        attachments = []
        rebuild()
        if waits {
            // Until the channel is back, or the drop has lasted long enough to be said.
            while sendWaits, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            guard canSend else {
                pending.removeAll { $0.id == message.id }
                if draft.isEmpty, attachments.isEmpty { draft = text; attachments = files }
                // The words are back in the input and the title says the rest: a mention is enough.
                notice = sendBlock ?? String(localized: "连接还没恢复，消息没有发出去")
                rebuild()
                return
            }
        }
        func settle(_ delivery: RemotePendingMessage.Delivery) {
            guard let index = pending.firstIndex(where: { $0.id == message.id }) else { return }
            pending[index].delivery = delivery
            rebuild()
        }
        var submitted = false
        do {
            var fileIds: [JSON] = []
            if !files.isEmpty {
                let uploaded = try await client.upload("\(path)/attachments", files: files)
                fileIds = uploaded["attachments"].array.compactMap { $0["fileId"].string }.map { ["fileId": .string($0)] }
            }
            submitted = true
            let value = try await client.post(steers ? "\(path)/runtime/steer" : "\(path)/runtime/messages", [
                "content": .string(text), "attachments": .array(fileIds), "clientMessageId": .string(message.id),
            ])
            try accepted(value)
            settle(.accepted)
        } catch {
            let failure = RemoteError(error)
            if !submitted || failure.definite {
                // It did not go: the words come back to the input, unless something new is being typed.
                pending.removeAll { $0.id == message.id }
                if draft.isEmpty, attachments.isEmpty { draft = text; attachments = files }
                self.error = failure.message
                rebuild()
            } else {
                settle(.uncertain(failure.message))
            }
        }
    }

    /// Drop a message whose delivery could not be confirmed.
    func dismiss(pending id: String) {
        let message = id.hasPrefix("pending-") ? String(id.dropFirst(8)) : id
        pending.removeAll { $0.id == message }
        rebuild()
    }

    func interrupt() async {
        _ = await act { client in try self.accepted(try await client.post("\(self.path)/runtime/interrupt")) }
    }

    /// Take the session over from the agent's own client, or hand it back (read-only here).
    func setTakeover(_ enabled: Bool) async {
        let done = await act { client in
            let value = enabled ? try await client.post("\(self.path)/takeover") : try await client.delete("\(self.path)/takeover")
            self.store?.upsert(value["session"])
            if let next = RemoteSession(value["session"]) { self.adopt(next) }
            self.fresh = false
        }
        if done, let client { try? await reconcile(client) }
    }

    /// Answer a request with one of its actions.
    func respond(_ notice: RemoteNotice, action: String, input: JSON? = nil) async -> Bool {
        var body: [String: JSON] = ["actionId": .string(action)]
        if let input { body["input"] = input }
        answering.insert(notice.id)
        let done = await act { client in
            try self.accepted(try await client.post("\(self.path)/runtime/notices/\(RemoteClient.encode(notice.id))/respond", .object(body)))
        }
        if !done { answering.remove(notice.id); return false }
        // Taken is not settled: the agent's own word follows over the channel.
        if let client { try? await reconcile(client) }
        return true
    }

    func respond(plan: RemotePlan, action: String, feedback: String = "") async -> Bool {
        await act { client in
            var body: [String: JSON] = [
                "command": .string(action), "operationId": .string(UUID().uuidString), "attachments": [],
                "reviewId": .string(plan.reviewId), "planId": .string(plan.planId), "planRevision": .number(Double(plan.revision)),
                "contentHash": .string(plan.contentHash), "epoch": .string(plan.epoch),
            ]
            if !feedback.isEmpty { body["feedback"] = .string(feedback) }
            let value = try await client.post("\(self.path)/planning", .object(body))
            guard value["ok"].bool == true else {
                throw RemoteError(kind: .rejected, message: value["message"].string ?? String(localized: "计划的回应没有被确认，请刷新后再试"))
            }
            self.plan = RemotePlan(value["state"])
        }
    }

    // MARK: Model, permission and commands

    func loadCatalog(force: Bool = false) async {
        guard current, force || catalog == nil, let client else { return }
        var next = RemoteCatalog()
        do {
            if capabilities.allows("catalog.model") {
                next.models = try await client.get("\(path)/runtime/catalogs/model")["catalog"]["models"].array.compactMap(RemoteModelOption.init)
            }
            if capabilities.allows("catalog.permission") {
                next.permissions = try await client.get("\(path)/runtime/catalogs/permission")["catalog"]["permissions"].array.compactMap(RemoteOption.init)
            }
            catalog = next
        } catch {
            report(error)
        }
    }

    /// `scope` is `model` (a level's id where the model has levels) or `permission`.
    func select(_ scope: String, _ selection: String) async {
        let done = await act { client in
            let value = try await client.patch("\(self.path)/runtime/selections", ["selections": [scope: .string(selection)]])
            guard value["ok"].bool == true else {
                throw RemoteError(kind: .rejected, message: value["connectorResult"]["error"]["message"].string ?? String(localized: "智能体没有接受这个选项"))
            }
            if let next = RemoteRuntimeState(value["state"]) { self.state = next }
        }
        if done { await loadCatalog(force: true) }
    }

    func loadCommands() async {
        guard canCommand, let client else { return }
        if let value = try? await client.get("\(path)/runtime/commands") {
            commands = value["commands"].array.compactMap(RemoteCommand.init)
        }
    }

    /// Commands the draft's `/…` could be, while it is still only the command's name.
    func suggestions(for text: String) -> [RemoteCommand] {
        guard let slash = RemoteSlash(text), slash.commandLike, slash.rest.isEmpty, !slash.multiline else { return [] }
        return commands.filter { $0.matches(slash.command) }
    }

    private func run(_ command: RemoteCommand, slash: RemoteSlash, raw: String) async {
        guard command.enabled else { error = command.disabledReason ?? String(localized: "这个会话暂时无法使用这条指令"); return }
        guard takeover else { error = String(localized: "接管后才能执行指令"); return }
        if command.selector != nil { optionsRequest += 1; draft = ""; return }
        guard command.runs(in: status) else { error = String(localized: "智能体正忙，暂时不能执行这条指令"); return }
        if slash.multiline, !command.multiline { error = String(localized: "这条指令不支持多行输入"); return }
        let rest = slash.rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty, !command.takesArguments { error = String(localized: "这条指令不接受参数"); return }
        let arguments: [JSON] = rest.isEmpty ? [] : command.wholeArgument
            ? [.string(slash.rest.first?.isWhitespace == true ? String(slash.rest.dropFirst()) : slash.rest)]
            : rest.split(whereSeparator: \.isWhitespace).map { .string(String($0)) }
        let done = await act { client in
            let value = try await client.post("\(self.path)/runtime/commands", ["command": .string(command.id), "args": .array(arguments), "raw": .string(raw)])
            self.store?.upsert(value["session"])
            guard value["ok"].bool == true else {
                throw RemoteError(kind: .rejected, code: value["code"].string, message: value["message"].string ?? String(localized: "指令没有执行"))
            }
        }
        if done, draft.trimmingCharacters(in: .whitespacesAndNewlines) == raw { draft = "" }
    }
}

extension RemoteSessionModel: KeptSession {
    var keptId: String { id }
}
