import Foundation
import Observation
import UIKit

/// One open conversation: follows the session's event stream and turns it
/// into a timeline, tracks live assistant output, and sends the user's actions.
@MainActor
@Observable
final class SessionModel {
    let sessionId: String
    @ObservationIgnored private let app: AppModel

    private(set) var items: [TimelineItem] = []
    /// Whether the timeline holds anything. For a view that asks only that: reading `items` there
    /// would redraw it at every change to the timeline.
    private(set) var hasItems = false
    private(set) var live: [AssistantBlock] = []
    private(set) var running = false
    private(set) var title: String?
    private(set) var todos: [TodoItem] = []
    /// Rows of the `userQuestions` projection that continued unanswered.
    private var continuedQuestions: [PendingQuestion] = []
    /// A timed-out question between its rejection and the projection saying it continued.
    private var detachedQuestions: [PendingQuestion] = []
    /// `userQuestions.settled`: answers by call id, for the tool row.
    private(set) var settledAnswers: [String: JSON] = [:]
    /// `state` of each call in `userQuestions.active`.
    private(set) var activeQuestionStates: [String: String] = [:]
    private(set) var questionWaits: [String: QuestionWait] = [:]
    private(set) var turnOutline: [TurnOutline] = []
    var questionDrafts: [String: QuestionDraft] = [:]

    /// What is waiting on the user: requests this client holds, then questions the agent moved on from.
    var questions: [PendingQuestion] {
        var result = (app.questionRequests[sessionId] ?? []).map(PendingQuestion.init)
        for question in detachedQuestions + continuedQuestions where !result.contains(where: { $0.id == question.id }) {
            result.append(question)
        }
        return result
    }
    private(set) var queued: [(id: String, text: String)] = []
    private(set) var modelSelection: (provider: String, model: String, effort: String?)?
    private(set) var permission: String?
    private(set) var tokens: (input: Int, output: Int, cacheRead: Int) = (0, 0, 0)
    private(set) var contextWindow: Int?
    private(set) var contextTokens: Int?
    private(set) var workingDirectory: String?
    private(set) var turnInfo: [Int: TurnInfo] = [:]
    private(set) var runningSince: Date?
    private(set) var hasMoreHistory = false
    private(set) var loadingOlder = false
    private(set) var loaded = false
    /// Every projection value of the latest snapshot or refresh, for the composer docks.
    @ObservationIgnored private var projectionValues: [String: Tracked<JSON?>] = [:]
    var error: String?
    /// A subagent's parent-scoped address; the Host refuses a plain session address
    /// for a child, and its messages and stops go through the parent. Set before `start()`.
    var subagentAddress: JSON?
    /// The child's own mode (`subagent` projection): tells an address opened as `unknown`.
    private(set) var subagentMode: String?
    /// The open conversation's model catalog; a prompt first moves off a model that no longer routes.
    @ObservationIgnored weak var modelCatalog: ComposerContext?
    /// Composer state (draft, local echoes, attachments): one per open conversation.
    @ObservationIgnored private(set) lazy var composer = ComposerModel(session: self, app: app)
    /// The voice call on this conversation hears its turns here: each start and end, and the
    /// answer's text as it streams, every delta as it comes (the view's own copy waits 80 ms).
    @ObservationIgnored var callListener: ((CallSignal) -> Void)?

    /// Durable events folded so far (the source of `items`).
    @ObservationIgnored private var timeline = TimelineBuilder()
    /// The events themselves, oldest first: a page of older history refolds from the start.
    @ObservationIgnored private var events: [JSON] = []
    @ObservationIgnored private var cursor = -1
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var liveAttempt: String?
    @ObservationIgnored private var livePartials: [Int: (kind: String, text: String, toolId: String?, toolName: String?)] = [:]
    /// Bumped for each assistant attempt. A live block's id has to differ from the next
    /// attempt's, or a sheet open on one thinking starts following the one after it.
    @ObservationIgnored private var liveGeneration = 0
    /// Live reasoning ids, to the durable block they settled into: an open sheet keeps its
    /// text when the attempt's live blocks are replaced by the committed message's.
    @ObservationIgnored private var reasoningSettlements: [String: String] = [:]
    /// Pending publish of `live`: chunks arrive per token, the view redraws at most this often.
    @ObservationIgnored private var livePublish: Task<Void, Never>?
    @ObservationIgnored private var waitClaims: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var waitTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 60
        // Only animated pictures count (`AnimatedPicture.cost`): their frames are decoded up front.
        cache.totalCostLimit = 120 << 20
        return cache
    }()
    @ObservationIgnored private let previewCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        return cache
    }()

    init(sessionId: String, app: AppModel) {
        self.sessionId = sessionId
        self.app = app
    }

    /// The last user message the latest `session/follow` snapshot held: the first one, a kept
    /// conversation catching up on its return, a reconnect. Those are history; only later ones
    /// were sent while the conversation was on screen.
    @ObservationIgnored private(set) var snapshotThrough = 0

    var client: EngineClient { app.client }

    // MARK: Following

    func start() {
        guard followTask == nil else { return }
        followTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    let stream = self.app.mux.open("session/follow", [
                        "request": [
                            "address": self.subagentAddress ?? ["kind": "session", "sessionId": .string(self.sessionId)],
                            "assistantStream": true,
                            "maxMessages": 500,
                            "turnWindow": ["minMessages": 50, "minTurns": 2],
                        ],
                    ])
                    for try await frame in stream {
                        await self.app.arrivalLanded()
                        self.apply(frame)
                    }
                } catch {
                    if Task.isCancelled { return }
                    // The engine refusing the stream is worth saying. A dropped connection is not: the
                    // engine restarting (after a plugin change) drops it, it is followed again in a
                    // second, and the shell's banner speaks for a connection that stays down.
                    if error is EngineError { self.error = error.localizedDescription }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        refreshProjections()
    }

    func stop() {
        followTask?.cancel()
        followTask = nil
        waitClaims.values.forEach { $0.cancel() }
        waitClaims = [:]
        waitTimers.values.forEach { $0.cancel() }
        waitTimers = [:]
    }

    private func apply(_ frame: JSON) {
        switch frame["type"].string {
        case "snapshot":
            events = frame["records"].array.map { $0["event"] }
            // A message sent as the stream dropped comes back in the snapshot, not as an event:
            // its echo is done with here, or its bubble would show twice.
            if !composer.pending.isEmpty { for event in events { composer.observe(event) } }
            hasMoreHistory = frame["hasMore"].bool ?? false
            // A long turn's start can lie before the window: the session list still knows it runs.
            refold(running: app.sessions[sessionId]?.running ?? false)
            cursor = frame["cursor"].int ?? -1
            applyProjections(frame["projections"]["values"])
            resetLive()
            snapshotThrough = timeline.items.reduce(0) { last, item in if case .user(let seq, _, _, _) = item { max(last, seq) } else { last } }
            publishTimeline()
            loaded = true
            error = nil
        case "event":
            let event = frame["event"]
            guard let seq = event["seq"].int, seq > cursor else { return }
            cursor = seq
            composer.observe(event)
            events.append(event)
            if timeline.apply(event) {
                bindSettledReasoning(event)
                publishTimeline()
            } else {
                publishTimelineState()
            }
            // Live only: recording what the agent does in other apps starts and stops with its turn.
            if subagentAddress == nil {
                PhoneRecorder.shared.observe(event, session: sessionId, request: items.lastUserText)
            }
            // Only a live turn end prompts for credentials or support; history replays never do.
            if event["type"].string == "turn/end" {
                if let failure = TurnFailure(reason: event["data"]["reason"]) {
                    // Out of balance is the conversation's card to say (QuotaNotice), never a popup:
                    // only re-read the balances it offers to top up.
                    if failure.isQuota {
                        if app.fishPocket.signedIn { Task { await app.fishPocket.refresh() } }
                        if failure.code == "ACCOUNT_QUOTA" { Task { await app.account.refreshDetails() } }
                    }
                    // A key that stopped working is the conversation's card to explain; none at all is the first step.
                    if failure.credentialProblem == .missing {
                        app.requestCredentials(modelCatalog?.selection(self)?.provider == FishPocketAPI.provider ? .fishPocket : .start)
                    }
                } else if event["data"]["reason"]["kind"].string == "completed", subagentAddress == nil, hasReply,
                          queued.isEmpty, composer.text.isEmpty {
                    app.noteCompletedTurn()
                }
            }
            if let callListener {
                switch event["type"].string {
                case "turn/start": callListener(.turnStarted)
                case "turn/end": callListener(.turnEnded(failed: TurnFailure(reason: event["data"]["reason"]) != nil))
                default: break
                }
            }
            switch event["type"].string {
            case "turn/end", "session/title", "tool/result", "user/message", "turn/start":
                refreshProjections()
                app.scheduleRefresh()
            default:
                break
            }
        case "assistant-stream":
            applyStream(frame["frame"])
        default:
            break
        }
    }

    /// Live assistant output between attempt start and its durable `assistant/message`.
    private func applyStream(_ frame: JSON) {
        switch frame["type"].string {
        case "start":
            resetLive()
            liveGeneration += 1
            liveAttempt = frame["attemptId"].string
            running = true
        case "chunk":
            guard frame["attemptId"].string == liveAttempt else { return }
            let chunk = frame["chunk"]
            let index = chunk["index"].int ?? 0
            switch chunk["type"].string {
            case "text-delta", "reasoning-delta":
                let kind = chunk["type"].string == "text-delta" ? "text" : "reasoning"
                var partial = livePartials[index] ?? (kind, "", nil, nil)
                partial.text += chunk["text"].string ?? ""
                livePartials[index] = partial
                if kind == "text", let text = chunk["text"].string, !text.isEmpty { callListener?(.text(text)) }
            case "tool-call-delta":
                var partial = livePartials[index] ?? ("tool", "", nil, nil)
                partial.toolId = chunk["id"].string ?? partial.toolId
                partial.toolName = chunk["name"].string ?? partial.toolName
                partial.text += chunk["argumentsDelta"].string ?? ""
                livePartials[index] = partial
            default:
                return
            }
            scheduleLivePublish()
        case "end":
            if frame["attemptId"].string == liveAttempt { resetLive() }
        default:
            break
        }
    }

    private func scheduleLivePublish() {
        guard livePublish == nil else { return }
        livePublish = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            self.livePublish = nil
            self.publishLive()
        }
    }

    private func publishLive() {
        let prefix = "live-\(liveGeneration)"
        live = livePartials.keys.sorted().compactMap { index in
            let partial = livePartials[index]!
            switch partial.kind {
            case "text": return .text(id: "\(prefix)-\(index)", text: partial.text)
            case "reasoning": return .reasoning(id: "\(prefix)-\(index)", text: partial.text)
            default:
                let args = (try? JSONDecoder().decode(JSON.self, from: Data(partial.text.utf8))) ?? .null
                return .tool(ToolCall(id: partial.toolId ?? "\(prefix)-\(index)", name: partial.toolName ?? "…", arguments: args, rawArguments: partial.text))
            }
        }
    }

    private func resetLive() {
        livePublish?.cancel()
        livePublish = nil
        liveAttempt = nil
        livePartials = [:]
        if !live.isEmpty { live = [] }
    }

    /// A reasoning block changes id when its attempt settles: live ids carry the attempt,
    /// durable ids the message part. Pair them, so an open sheet stays on the same text.
    private func bindSettledReasoning(_ event: JSON) {
        guard event["type"].string == "assistant/message",
              let seq = event["seq"].int else { return }
        let parts = event["data"]["message"]["content"].array
        for (index, part) in parts.enumerated() where part["type"].string == "reasoning" {
            let liveId = "live-\(liveGeneration)-\(index)"
            guard let settled = part["text"].string, !settled.isEmpty,
                  let block = live.first(where: { $0.id == liveId }),
                  case .reasoning(_, let text) = block,
                  !text.isEmpty, settled.hasPrefix(text) else { continue }
            reasoningSettlements[liveId] = "\(seq)-\(index)"
        }
    }

    /// The durable block a live reasoning block settled into, when it has.
    func settledReasoningId(_ id: String) -> String? { reasoningSettlements[id] }

    // MARK: Timeline

    /// Publish the timeline after the builder changed; values are compared first so
    /// unrelated observers are not invalidated.
    private func publishTimeline() {
        items = timeline.items
        hasItems = !items.isEmpty
        if turnInfo != timeline.turnInfo { turnInfo = timeline.turnInfo }
        publishTimelineState()
    }

    private func publishTimelineState() {
        if let value = timeline.title, value != title { title = value }
        if liveAttempt == nil, running != timeline.running { running = timeline.running }
        if runningSince != timeline.runningSince { runningSince = timeline.runningSince }
    }

    /// The row to scroll to for a turn, paging back to it first when it is not loaded yet (C-14).
    func anchor(of entry: TurnOutline) async -> String? {
        while hasMoreHistory, let first = events.first?["seq"].int, first > entry.seq {
            let before = events.count
            await loadOlder(minMessages: 200)
            if events.count == before { break }
        }
        let index = items.firstIndex { if case .assistant(let turn, _, _, _) = $0 { return turn == entry.turn }; return false }
        guard let index else { return nil }
        // Start at its prompt.
        if index > 0, case .user = items[index - 1] { return rowId(items[index - 1]) }
        return rowId(items[index])
    }

    /// The timeline row an item sits in, which is also what the timeline scrolls to. A message
    /// that showed as a bubble the moment it was sent keeps that row when its durable message
    /// arrives: the bubble is neither built nor animated a second time.
    func rowId(_ item: TimelineItem) -> String {
        if case .user(_, _, _, let requestId?) = item, composer.bubbleIds.contains(requestId) { return Self.bubbleRow(requestId) }
        return item.id
    }

    static func bubbleRow(_ requestId: String) -> String { "e\(requestId)" }

    #if DEBUG
    /// `-dshOpen timeline`: show synthetic events instead of the session's, to look at every card.
    func debugLoadFixture(_ fixture: [JSON]) {
        stop()
        events = fixture
        hasMoreHistory = false
        refold(running: false)
        publishTimeline()
        loaded = true
    }
    #endif

    private func refold(running: Bool) {
        var timeline = TimelineBuilder()
        timeline.historyComplete = !hasMoreHistory
        timeline.running = running
        for event in events { timeline.apply(event) }
        self.timeline = timeline
    }

    /// Read the page before the oldest loaded event (C-11). The window options are
    /// the web's: up to 500 messages, at least 50 messages and 2 turn starts.
    func loadOlder(minMessages: Int = 50) async {
        guard hasMoreHistory, !loadingOlder, let first = events.first?["seq"].int else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let reply = try await client.call("session/page", ["request": [
                "address": ["kind": "session", "sessionId": .string(sessionId)],
                "throughSeq": .number(Double(cursor)),
                "beforeSeq": .number(Double(first)),
                "maxMessages": 500,
                "turnWindow": ["minMessages": .number(Double(minMessages)), "minTurns": 2],
            ]])
            // A snapshot arriving meanwhile replaced the window; this page no longer joins it.
            guard events.first?["seq"].int == first else { return }
            let page = reply["records"].array.map { $0["event"] }.filter { ($0["seq"].int ?? first) < first }
            events.insert(contentsOf: page, at: 0)
            hasMoreHistory = reply["hasMore"].bool ?? false
            refold(running: timeline.running)
            publishTimeline()
        } catch {
            app.showToast(String(localized: "加载失败：") + error.localizedDescription)
        }
    }

    // MARK: Projections

    func refreshProjections() {
        projectionTask?.cancel()
        projectionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            if let value = try? await self.client.call("session/projections", ["request": ["sessionId": .string(self.sessionId)]]) {
                self.applyProjections(value["values"])
            }
        }
    }

    /// One projection value from the session's latest read (`session/projections`), observed by
    /// itself like the live ones (`AppModel.control`).
    func projectionValue(_ key: String) -> JSON? {
        if let held = projectionValues[key] { return held.value }
        let held = Tracked<JSON?>(nil)
        projectionValues[key] = held
        return held.value
    }

    private func applyProjections(_ values: JSON) {
        // This runs after every event of a turn and most of what it reads is the same each time.
        // Setting an observed property to an equal value redraws nothing, so the plain writes below
        // cost nothing; the tuples and the in-place removal cannot be compared that way, and check
        // for themselves.
        let latest = values.object
        for (key, held) in projectionValues where latest[key] == nil { held.value = nil }
        for (key, value) in latest {
            if let held = projectionValues[key] { held.value = value } else { projectionValues[key] = Tracked(value) }
        }
        if let value = values["title"].string { title = value }
        if let mode = values["subagent"]["mode"].string { subagentMode = mode }
        todos = values["todos"].array.map { TodoItem(content: $0["content"].string ?? "", status: $0["status"].string ?? "pending") }
        let inbox = values["inbox"]["next-step"].array + values["inbox"]["next-turn"].array
        // A reply already waiting in the inbox: nothing left to answer until it is admitted or dropped.
        let replied = Set(inbox.filter { $0["source"]["kind"].string == "user-question-reply" }.compactMap { $0["source"]["callId"].string })
        let active = values["userQuestions"]["active"].array
        activeQuestionStates = Dictionary(active.map { ($0["callId"].string ?? "", $0["state"].string ?? "open") }, uniquingKeysWith: { $1 })
        continuedQuestions = active
            .filter { $0["state"].string == "continued" && !replied.contains($0["callId"].string ?? "") }
            .map(PendingQuestion.init(continued:))
        if detachedQuestions.contains(where: { activeQuestionStates[$0.id] != "open" }) {
            detachedQuestions.removeAll { activeQuestionStates[$0.id] != "open" }
        }
        settledAnswers = Dictionary(values["userQuestions"]["settled"].array.map { ($0["callId"].string ?? "", $0["answers"]) }, uniquingKeysWith: { $1 })
        turnOutline = values["turnOutline"].array.compactMap(TurnOutline.init)
        let selection = values["modelSelection"]["next"].isNull ? values["modelSelection"]["lastUsed"] : values["modelSelection"]["next"]
        if let provider = selection["provider"].string, let model = selection["model"].string {
            let next = (provider, model, selection["reasoningEffort"].string)
            if modelSelection.map({ $0 == next }) != true { modelSelection = next }
        }
        permission = values["permissions"]["currentValue"].string ?? permission
        let usage = values["tokenUsage"]
        let used = ((usage["uncachedInputTokens"].int ?? 0) + (usage["cacheReadTokens"].int ?? 0), usage["outputTokens"].int ?? 0, usage["cacheReadTokens"].int ?? 0)
        if tokens != used { tokens = used }
        contextWindow = values["contextPressure"]["contextWindow"].int ?? contextWindow
        contextTokens = values["contextPressure"]["projectedTokens"].int ?? values["contextPressure"]["pressureTokens"].int ?? contextTokens
        workingDirectory = values["workingDirectory"].string ?? workingDirectory
        let waiting = values["inbox"]["next-turn"].array.filter { $0["source"]["kind"].string != "user-question-reply" }.map { item in
            (id: item["itemId"].string ?? item["id"].string ?? UUID().uuidString,
             text: item["content"].array.compactMap { $0["text"].string }.joined(separator: "\n"))
        }
        if !waiting.elementsEqual(queued, by: ==) { queued = waiting }
    }

    // MARK: Actions

    /// Send a message; while a turn runs it is queued (or steers it when `steer`).
    /// Failures land in `error`; the composer sends through `prompt` instead.
    func send(text: String, images: [(mediaType: String, data: String, name: String)] = [], steer: Bool = false) async {
        var content: [JSON] = images.map { ["type": "image", "mediaType": .string($0.mediaType), "data": .string($0.data), "name": .string($0.name)] }
        if !text.isEmpty { content.append(["type": "text", "text": .string(text)]) }
        guard !content.isEmpty else { return }
        do {
            try await prompt(content: content, steer: steer, requestId: UUID().uuidString.lowercased())
        } catch let error as EngineError where error.code == "session/writer-held" {
            app.showToast(String(localized: "当前会话已被占用，可能是其他正在运行的 DSH 导致的（如其他 dsh web、桌面端），请退出其他正在运行的 DSH 后重试。"), duration: 6)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A model has answered here: a failed turn leaves no blocks.
    var hasReply: Bool {
        items.contains { if case .assistant(_, let blocks, _, _) = $0 { !blocks.isEmpty } else { false } }
    }

    /// `session/prompt` as the web sends it: attachments before the text, the
    /// client's request id (it comes back as `source.rpcId` on the durable message).
    func prompt(content: [JSON], steer: Bool, requestId: String) async throws {
        await modelCatalog?.adoptRoutableModel(self)
        if let subagentAddress {
            try await client.call("subagents/prompt", ["request": [
                "requestId": .string(requestId),
                "childSessionId": subagentAddress["childSessionId"],
                "delivery": .string(steer ? "steer" : "queue"),
                "content": .array(content),
                "clientTimeZone": .string(TimeZone.current.identifier),
            ]])
            return
        }
        try await client.call("session/prompt", ["request": [
            "requestId": .string(requestId),
            "sessionId": .string(sessionId),
            "mode": .string(steer ? "steer" : "queue"),
            "content": .array(content),
            "clientTimeZone": .string(TimeZone.current.identifier),
        ]])
    }

    /// Whether the Host would run the failed turn that ended at `seq` again (`conversationContinuation`
    /// names its `turn/end` after a rate limit, a server or transport failure, a timeout, an empty or
    /// cut-off answer), and nothing else is on its way in.
    func canContinue(after seq: Int) -> Bool {
        composer.projection("conversationContinuation").int == seq && !running && subagentAddress == nil
            && composer.isEmpty && composer.pending.isEmpty && queued.isEmpty
    }

    /// 继续生成: a prompt with no content, which the Host records as a retry of that turn.
    func continueGeneration() async {
        do {
            try await prompt(content: [], steer: false, requestId: UUID().uuidString.lowercased())
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toast(_ text: String, duration: Double = 4) { app.showToast(text, duration: duration) }

    func cancel() async {
        do {
            if let subagentAddress {
                // 0.2.2-rc.3 replaced interruptByParent: the Gateway authorizes on the child Session,
                // so the parent address is no longer part of the request.
                try await client.call("subagents/interruptByUser", [
                    "childSessionId": subagentAddress["childSessionId"],
                ])
            } else {
                try await client.call("session/cancel", ["request": ["sessionId": .string(sessionId)]])
            }
        }
        catch { self.error = error.localizedDescription }
    }

    /// Edit, remove or steer one queued message; throws so the queue dock can say which failed.
    func updateQueue(_ itemId: String, action: JSON) async throws {
        try await client.call("session/updateQueue", ["request": ["sessionId": .string(sessionId), "itemId": .string(itemId), "action": action]])
        refreshProjections()
    }

    /// A failure the sheet should show, or nil once the answer is on its way.
    func answer(_ question: PendingQuestion, draft: QuestionDraft) async -> String? {
        let payload: [JSON] = question.questions.map { q in
            let answer = draft.answers[q.id] ?? .init()
            if answer.skipped { return ["id": .string(q.id), "selected": []] }
            let custom = answer.custom.trimmingCharacters(in: .whitespacesAndNewlines)
            // Single choice: the custom text replaces the option.
            let selected = !q.multiSelect && !custom.isEmpty ? [] : Array(answer.selected)
            var entry: [String: JSON] = ["id": .string(q.id), "selected": .array(selected.map { .string($0) })]
            if !custom.isEmpty { entry["custom"] = .string(custom) }
            return .object(entry)
        }
        return await sendAnswer(question, ["answers": .array(payload)])
    }

    func approvePlan(_ question: PendingQuestion, review: PlanReview) async -> String? {
        await sendAnswer(question, ["answers": [["id": .string(review.questionId), "selected": [.string(review.approveLabel)]]]])
    }

    /// 「要求修改」: the tool ends the turn and the user replies in the composer.
    func declineQuestion(_ question: PendingQuestion) async {
        guard let eventId = question.eventId else { return }
        await reject(eventId, code: "ASK_CANCELLED", message: "the user cancelled ask_user_question")
        finishWait(question)
    }

    private func sendAnswer(_ question: PendingQuestion, _ answer: JSON) async -> String? {
        if let eventId = question.eventId {
            // In this order: releasing the claim first would restart the host's timer,
            // which fires at once when the original deadline has already passed.
            guard await app.settleQuestion(eventId, session: sessionId, outcome: ["kind": "result", "value": answer]) else {
                return String(localized: "当前无法提交，请稍候再试。")
            }
            finishWait(question)
            questionDrafts[question.id] = nil
            refreshProjections()
            return nil
        }
        guard let callId = question.callId, activeQuestionStates[callId] == "continued" else {
            return String(localized: "当前无法提交，请稍候再试。")
        }
        do {
            let reply = try await client.call("userQuestions/answer", ["agentId": .string(sessionId), "callId": .string(callId), "answer": answer])
            guard reply.bool != false else { return String(localized: "这个问题已结束，无法再回答。") }
            questionDrafts[question.id] = nil
            detachedQuestions.removeAll { $0.id == question.id }
            refreshProjections()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func reject(_ eventId: String, code: String, message: String) async {
        await app.settleQuestion(eventId, session: sessionId, outcome: [
            "kind": "rejected",
            "error": ["name": "UserQuestionError", "message": .string(message), "code": .string(code)],
        ])
    }

    // MARK: Question waits

    /// Claim the wait of each timed question held by this client, once, while the conversation is open.
    /// Attaching stops the host's timer until the claim ends; the first frame says how long is left.
    func syncQuestionWaits() {
        let requests = app.questionRequests[sessionId] ?? []
        for request in requests where request.timed {
            guard let callId = request.callId, waitClaims[callId] == nil else { continue }
            waitClaims[callId] = Task { [weak self] in
                guard let self else { return }
                var opened = false
                do {
                    let stream = self.app.mux.open("userQuestions/attachWait", ["agentId": .string(self.sessionId), "callId": .string(callId)])
                    for try await frame in stream {
                        guard !opened, let remaining = frame["remainingMs"].double else { continue }
                        opened = true
                        self.startCountdown(callId, eventId: request.eventId, remaining: remaining / 1000)
                    }
                } catch {}
                guard !Task.isCancelled else { return }
                self.waitClaims[callId] = nil
                self.waitTimers[callId]?.cancel()
                self.waitTimers[callId] = nil
                self.questionWaits[callId] = nil
                // The wait is gone: nothing timed here any more, so hand the request on as the web does.
                guard let held = self.app.questionRequests[self.sessionId]?.first(where: { $0.eventId == request.eventId }) else { return }
                if opened {
                    await self.app.settleQuestion(held.eventId, session: self.sessionId, outcome: [
                        "kind": "rejected", "error": ["name": "Error", "message": "the foreground question wait ended"],
                    ])
                } else {
                    await self.app.settleQuestion(held.eventId, session: self.sessionId, outcome: ["kind": "next"])
                }
            }
        }
    }

    private func startCountdown(_ callId: String, eventId: String, remaining: TimeInterval) {
        // A draft restored from an earlier sheet already stopped the clock.
        if questionWaits[callId] == nil { questionWaits[callId] = .counting(deadline: Date().addingTimeInterval(remaining)) }
        scheduleTimeout(callId, eventId: eventId)
    }

    private func scheduleTimeout(_ callId: String, eventId: String) {
        waitTimers[callId]?.cancel()
        guard case .counting(let deadline) = questionWaits[callId] else { return }
        waitTimers[callId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled, case .counting = self.questionWaits[callId] else { return }
            await self.timedOut(callId, eventId: eventId)
        }
    }

    /// Zero: the tool returns `pending` and the agent goes on; the question stays answerable.
    private func timedOut(_ callId: String, eventId: String) async {
        questionWaits[callId] = nil
        if let request = app.questionRequests[sessionId]?.first(where: { $0.eventId == eventId }) {
            var question = PendingQuestion(request)
            question.eventId = nil
            detachedQuestions.append(question)
            await reject(eventId, code: "ASK_TIMED_OUT", message: "ask_user_question timed out before the user answered")
        }
        waitClaims[callId]?.cancel()
        waitClaims[callId] = nil
        waitTimers[callId] = nil
    }

    private func finishWait(_ question: PendingQuestion) {
        guard let callId = question.callId else { return }
        waitClaims[callId]?.cancel()
        waitClaims[callId] = nil
        waitTimers[callId]?.cancel()
        waitTimers[callId] = nil
        questionWaits[callId] = nil
    }

    /// 「慢慢回答」, or a first answer (`engage`): the countdown stops for good.
    func stopCountdown(_ question: PendingQuestion, held: Bool) {
        guard let callId = question.callId, let wait = questionWaits[callId], wait != .held else { return }
        if !held, wait == .editing { return }
        questionWaits[callId] = held ? .held : .editing
        waitTimers[callId]?.cancel()
        waitTimers[callId] = nil
    }

    /// The custom answer field took or lost focus: the countdown freezes meanwhile.
    func setAnswerFocus(_ question: PendingQuestion, focused: Bool) {
        guard let callId = question.callId, let eventId = question.eventId else { return }
        switch questionWaits[callId] {
        case .counting(let deadline) where focused:
            questionWaits[callId] = .focused(remaining: max(0, deadline.timeIntervalSinceNow))
            waitTimers[callId]?.cancel()
            waitTimers[callId] = nil
        case .focused(let remaining) where !focused:
            questionWaits[callId] = .counting(deadline: Date().addingTimeInterval(remaining))
            scheduleTimeout(callId, eventId: eventId)
        default:
            break
        }
    }

    func selectModel(_ choice: ModelChoice, effort: String?) async {
        do { try await applyModel(provider: choice.provider, model: choice.model, effort: effort) }
        catch { self.error = error.localizedDescription }
    }

    func applyModel(provider: String, model: String, effort: String?) async throws {
        var request: [String: JSON] = ["sessionId": .string(sessionId), "provider": .string(provider), "model": .string(model)]
        if let effort { request["reasoningEffort"] = .string(effort) }
        try await client.call("session/selectModel", ["request": .object(request)])
        modelSelection = (provider, model, effort)
        refreshProjections()
    }

    func runCommand(_ line: String) async {
        do { try await executeCommand(line) }
        catch { self.error = error.localizedDescription }
    }

    /// `commands/execute`: nil when the engine knows no such command, else
    /// `{commandId, result: {kind: success|error, text?}}`.
    @discardableResult
    func executeCommand(_ line: String, attachments: [JSON] = []) async throws -> JSON {
        try await client.call("commands/execute", ["agentId": .string(sessionId), "line": .string(line), "submittedAttachments": .array(attachments)])
    }

    /// Where a fork "from here" cuts: the end of `turn`, if it has ended.
    func forkBoundary(turn: Int) -> Int? { timeline.turnEndSeq[turn] }

    /// `session/attachment` takes the whole stored ref since 0.2.2, not just its id.
    func loadAttachment(_ attachment: Attachment) async -> Data? {
        guard let ref = attachment.ref,
              let value = try? await client.call("session/attachment", ["request": ["sessionId": .string(sessionId), "attachment": ref]]),
              let base64 = value["data"].string else { return nil }
        return Data(base64Encoded: base64)
    }

    /// A decoded attachment image; attachments are immutable, so each is read once per session.
    func image(_ attachment: Attachment) async -> UIImage? {
        guard let attachmentId = attachment.attachmentId else { return nil }
        if let hit = imageCache.object(forKey: attachmentId as NSString) { return hit }
        // An animation this device sent plays from its original; the engine keeps only a still.
        var data = SentAnimations.data(for: attachmentId)
        if data == nil { data = await loadAttachment(attachment) }
        guard let data,
              let image = await Task.detached(priority: .userInitiated, operation: { AnimatedPicture.picture(data) }).value else { return nil }
        imageCache.setObject(image, forKey: attachmentId as NSString, cost: AnimatedPicture.cost(image))
        return image
    }

    func cachedImage(_ attachmentId: String) -> UIImage? { imageCache.object(forKey: attachmentId as NSString) }

    /// An image of a message just sent, as it was picked: its bubble shows this until the stored
    /// copy is read (`AttachmentThumb`).
    func keepPreview(_ preview: UIImage, for attachmentId: String) { previewCache.setObject(preview, forKey: attachmentId as NSString) }

    func preview(_ attachmentId: String) -> UIImage? { previewCache.object(forKey: attachmentId as NSString) }
}

/// Kept between visits by `AppModel.localSessions`: opened again, the timeline is already there and
/// `session/follow` catches up behind it (its snapshot replaces the window with the current one).
extension SessionModel: KeptSession {
    var keptId: String { sessionId }
    func resume() { start() }
    func park() { stop() }
    func suspend() { stop() }
    func close() { stop() }
}

extension [TimelineItem] {
    /// The user's latest message: what the running turn answers.
    var lastUserText: String? {
        for item in reversed() { if case .user(_, let text, _, _) = item { return text } }
        return nil
    }
}
