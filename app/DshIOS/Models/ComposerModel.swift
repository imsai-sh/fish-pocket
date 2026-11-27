import CoreTransferable
import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// A message sent but not yet seen in the session (C-20): it shows as its bubble or as
/// 「发送中…」 until the durable message, or the queue row, carrying its request id arrives.
struct PendingSubmission: Identifiable, Equatable {
    enum Placement { case transcript, queued, steering }
    /// The request id (`source.rpcId` on the durable message).
    let id: String
    var text: String
    /// The attachments by name, for the queue and 「发送中…」.
    var attachments: [String]
    /// The attachments as the Host stored them, the blocks the durable message will carry; nil
    /// when one of them was not uploaded ahead (an image in a subagent's conversation).
    var stored: [Attachment]?
    /// Where the web shows the echo: idle → the transcript, busy → the queue or a steering bubble.
    var placement: Placement

    /// On screen at once as its bubble, in the row its durable message takes over: sent into an
    /// idle conversation, with everything it carries already stored. A message with an image
    /// that goes with the request waits for the durable message.
    var showsBubble: Bool { placement == .transcript && stored != nil }
}

/// One attachment waiting in the composer (C-104…C-106). A file or an image uploads as
/// soon as it is added and the prompt cites its receipt, the way the web sends them: the
/// Host checks, scales down and stores an image as it arrives, and the app keeps only a
/// preview in memory. Where the Host stages no image uploads (a subagent continuation, a
/// command) an image's bytes ride the request as base64, read from its file then.
struct DraftAttachment: Identifiable {
    enum Kind {
        /// The bytes to send wait in a file of their own under `tmp/uploads`.
        case image(mediaType: String, file: URL, preview: UIImage)
        case file(url: URL)
        /// A video still coming out of the photo library: it becomes `.file` when it arrives.
        case reading
    }
    enum Upload: Equatable {
        /// Before the upload: the library is handing the video over (nil: how far is unknown).
        case reading(fraction: Double?)
        case uploading(loaded: Int64, total: Int64?)
        case ready(receiptId: String)
        case failed(String)
    }
    let id = UUID()
    var name: String
    var bytes: Int
    var kind: Kind
    var upload: Upload?
    /// What the Host stored for it, from the reply to its upload: the block its message will carry.
    var stored: Attachment?

    var isImage: Bool { if case .image = kind { true } else { false } }

    /// The private copy of its bytes, in a folder of its own under `tmp/uploads`.
    var file: URL? {
        switch kind {
        case .image(_, let file, _): file
        case .file(let url): url
        case .reading: nil
        }
    }

    /// Drop the private copy: the Host has the bytes, or the attachment is gone.
    func removeCopy() {
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }
}

/// A video picked in the photo library, copied out as a file: the library hands over a
/// temporary file that is gone once the import returns.
struct PickedMovie: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMovie(url: try stage(received.file))
        }
    }

    /// Copy a file into a folder of its own under `tmp/uploads`, keeping its name.
    static func stage(_ file: URL) throws -> URL {
        let copy = try place(named: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// Write bytes into a folder of their own under `tmp/uploads`, under this name.
    static func stage(_ data: Data, name: String) throws -> URL {
        let copy = try place(named: name)
        try data.write(to: copy)
        return copy
    }

    private static func place(named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("uploads/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }
}

/// Files another app shared, in the folder the app took them into (`ShareInbox.take`).
struct SharedFiles: Hashable {
    var urls: [URL]
    var folder: URL
}

/// One `/` command of the session's catalog (`commands/list`).
struct CommandDescriptor: Identifiable, Hashable {
    var name: String
    var description: String
    var definitionId: String?
    /// `input.hint`: the command takes arguments (a leading claim), shown while they are empty.
    var hint: String?
    var acceptsAttachments: Bool
    var id: String { name }

    /// First-party commands by definition, whose face and localized alias the client owns.
    static let builtins: [String: String] = [
        "goal": "@deepseek-ai/dsh-command-goal",
        "plan": "@deepseek-ai/dsh-plan-mode",
        "compact": "@deepseek-ai/dsh-command-compact",
        "permission": "@deepseek-ai/dsh-permission-presets",
        "export": "@deepseek-ai/dsh-session-log-export",
    ]
    /// `/目标`, `/计划`…: both locales' tokens reach the built-in definition.
    static let aliases: [String: String] = [
        "目标": "goal", "计划": "plan", "压缩": "compact", "权限": "permission", "导出": "export",
        "goal": "goal", "plan": "plan", "compact": "compact", "permission": "permission", "export": "export",
    ]

    var builtinName: String? { Self.builtins.first { $0.value == definitionId }?.key }
}

/// Image limits from the `imageLimits` projection, with the web's defaults.
struct ImageLimits {
    var mediaTypes = ["image/png", "image/jpeg", "image/webp", "image/gif"]
    var maxImagesPerMessage = 20
    var maxImageBytes = 20 * 1024 * 1024
    var maxMessageImageBytes = 200 * 1024 * 1024
    var maxImagePixels = 64_000_000
    var maxImageDimension = 8192

    init(_ json: JSON) {
        if !json["mediaTypes"].array.isEmpty { mediaTypes = json["mediaTypes"].array.compactMap(\.string) }
        maxImagesPerMessage = json["maxImagesPerMessage"].int ?? maxImagesPerMessage
        maxImageBytes = json["maxImageBytes"].int ?? maxImageBytes
        maxMessageImageBytes = json["maxMessageImageBytes"].int ?? maxMessageImageBytes
        maxImagePixels = json["maxImagePixels"].int ?? maxImagePixels
        maxImageDimension = json["maxImageDimension"].int ?? maxImageDimension
    }

    /// `10MB`, `2.5MB` as the web writes sizes in its limit copy.
    static func sizeText(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb.rounded() == mb ? "\(Int(mb))MB" : String(format: "%.1fMB", mb)
    }
}

/// A row of the queue dock: one `inbox['next-turn']` message.
struct QueueRow: Identifiable, Equatable {
    let id: String
    /// Its text whole, to give back to the input when it is withdrawn.
    var text: String
    /// The request it came in with (`source.rpcId`): this client's echo of it, if any, goes with it.
    var requestId: String?
    var preview: String
    var attachments: [String]
}

/// The session's goal (`goal` projection, C-121).
struct GoalInfo: Equatable {
    var id: String
    var revision: Int
    var objective: String
    var phase: String
    var blockedReason: String?
}

/// The composer of one conversation: the draft (persisted per session, C-92),
/// attachments and their uploads, the optimistic send with local echoes and
/// failure restore (C-20, C-91), commands, the queue and the goal actions.
@MainActor
@Observable
final class ComposerModel {
    /// Weak: sends and uploads outlive the conversation that started them (the session owns this model).
    @ObservationIgnored private weak var session: SessionModel?
    @ObservationIgnored let sessionId: String
    @ObservationIgnored let app: AppModel

    var text: String { didSet { if text != oldValue { persistDraft() } } }
    /// Text quoted from the conversation, in the order added. Each is sent as a blockquote ahead of
    /// the text (`MessageQuotes.compose`) and kept with the draft (C-92).
    private(set) var quotes: [String] = [] { didSet { if quotes != oldValue { persistDraft() } } }
    private(set) var attachments: [DraftAttachment] = []
    private(set) var pending: [PendingSubmission] = []
    /// Request ids of the messages shown as bubbles before the Host had them (`showsBubble`):
    /// their durable messages keep those rows (`SessionModel.rowId`).
    private(set) var bubbleIds: Set<String> = []
    /// A command line being executed: sending waits for it (C-87).
    private(set) var executing = false
    /// The live goal activation (`goals/get`): whether the goal will continue on its own.
    private(set) var goalActivation: (id: String, revision: Int, armed: Bool)?
    /// `/plan` or `/plan off` on its way.
    private(set) var planSwitching = false
    /// `/compact` on its way.
    private(set) var compacting = false
    /// `agentTeams/setEnabled` on its way.
    private(set) var teamSwitching = false
    /// Bumped to ask the input for the keyboard (from outside it, or after a sheet).
    private(set) var focusRequest = 0
    /// Hold-to-talk: the bar's voice mode and the recording under the finger.
    @ObservationIgnored let voice = VoiceInput()
    /// Cleared here; hidden until the projection catches up.
    private var clearedGoalId: String?

    @ObservationIgnored private var failedDrafts: [(seq: Int, text: String, quotes: [String])] = []
    @ObservationIgnored private var restoredText: String?
    @ObservationIgnored private var restoredQuotes: [String] = []
    @ObservationIgnored private var sendSeq = 0
    @ObservationIgnored private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var uploadQueue: [UUID] = []
    @ObservationIgnored private var activeUploads = 0
    /// The library's progress for each video still being read (`readMovie`); cancel stops the read.
    @ObservationIgnored private var reads: [UUID: Progress] = [:]
    /// `ui-conversation.maxConcurrentFileUploads` (C-150): the web's default, a client config the phone does not receive.
    static let maxConcurrentFileUploads = 2

    init(session: SessionModel, app: AppModel) {
        self.session = session
        sessionId = session.sessionId
        self.app = app
        let draft = Self.loadDraft(session.sessionId)
        text = draft.text
        quotes = draft.quotes
        mentions = draft.mentions
        if draft.dropped {
            DraftStore.shared.write(nil, for: sessionId)
            app.showToast(String(localized: "上次的草稿太长，没有放回输入框"))
        }
    }

    // MARK: Projections

    /// The live value from `session/control`, else the session's latest snapshot.
    func projection(_ key: String) -> JSON {
        if let live = app.control(sessionId, key) { return live }
        return session?.projectionValue(key) ?? .null
    }

    var imageLimits: ImageLimits { ImageLimits(projection("imageLimits")) }

    /// Plan mode is the effective target: a pending toggle flips the active value.
    var planActive: Bool {
        let plan = projection("plan")
        let active = plan["active"].bool ?? false
        return (plan["pending"].bool ?? false) ? !active : active
    }

    /// Agent teamwork is this session's own choice, off in a new one (`agentTeam`:
    /// `{enabled, tasks, failure?}`); nil from a Host that has none.
    var teamEnabled: Bool? { projection("agentTeam")["enabled"].bool }

    /// Once the session has asked a model, turning teamwork off costs it its cached prefix: the web confirms first.
    var teamDisableNeedsConfirmation: Bool { !projection("modelSelection")["lastUsed"].isNull }

    var goal: GoalInfo? {
        let goal = projection("goal")["goal"]
        guard let id = goal["id"].string else { return nil }
        return GoalInfo(id: id, revision: goal["revision"].int ?? 0, objective: goal["objective"].string ?? "",
                        phase: goal["phase"].string ?? "active", blockedReason: goal["blockedReason"]["message"].string)
    }

    /// The goal to show: not complete, not just cleared.
    var visibleGoal: GoalInfo? {
        guard let goal, goal.phase != "complete", goal.id != clearedGoalId else { return nil }
        return goal
    }

    /// Whether this goal will continue on its own, once `goals/get` has answered for this revision.
    func armed(_ goal: GoalInfo) -> Bool? {
        goalActivation.flatMap { $0.id == goal.id && $0.revision == goal.revision ? $0.armed : nil }
    }

    func goalPaused(_ goal: GoalInfo) -> Bool {
        goal.phase == "paused" || (goal.phase != "blocked" && armed(goal) == false)
    }

    /// A goal the user paused is 已暂停; an active one that will not go on by itself is 待继续.
    func goalPhaseName(_ goal: GoalInfo) -> String {
        switch goal.phase {
        case "blocked": return String(localized: "受阻的目标")
        case "paused": return String(localized: "已暂停的目标")
        default: return armed(goal) == false ? String(localized: "待继续的目标") : String(localized: "进行中的目标")
        }
    }

    /// `contextPressure`: used = projected ?? pressure tokens, over the route's window.
    var contextOccupancy: (percent: Int, used: Int, window: Int)? {
        let pressure = projection("contextPressure")
        guard let used = pressure["projectedTokens"].int ?? pressure["pressureTokens"].int,
              let window = pressure["contextWindow"].int, window > 0 else { return nil }
        return (min(100, Int((Double(used) / Double(window) * 100).rounded())), used, window)
    }

    /// From here on the status bar offers `/compact`; below it the figure stays in the workbench.
    var contextNearlyFull: Bool { (contextOccupancy?.percent ?? 0) >= 80 }

    var contextBreakdown: (system: Int, tools: Int, messages: Int)? {
        let value = projection("contextBreakdown")
        guard let system = value["systemTokens"].int, let tools = value["toolsTokens"].int, let messages = value["messageTokens"].int else { return nil }
        return (system, tools, messages)
    }

    var todos: [TodoItem] {
        projection("todos").array.map { TodoItem(content: $0["content"].string ?? "", status: $0["status"].string ?? "pending") }
    }

    /// Queued messages, without the ones still showing as this client's transcript echo.
    var queueRows: [QueueRow] { inboxRows("next-turn") }

    /// Messages steered into the running turn, waiting for its current step to end (a long
    /// command can hold them a while). Answers to a question wait there too: they are not these.
    var steerRows: [QueueRow] { inboxRows("next-step") }

    private func inboxRows(_ lane: String) -> [QueueRow] {
        let inTranscript = Set(pending.filter { $0.placement == .transcript }.map(\.id))
        return projection("inbox")[lane].array.compactMap { item in
            if item["source"]["kind"].string == "user-question-reply" { return nil }
            if let rpc = item["source"]["rpcId"].string, inTranscript.contains(rpc) { return nil }
            let content = item["content"].array
            let texts = content.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }
            let attachments = content.filter { $0["type"].string != "text" }.map { block in
                block["attachment"]["name"].string ?? block["name"].string ?? (block["type"].string == "image" ? String(localized: "图片") : String(localized: "文件"))
            }
            let joined = texts.joined()
            return QueueRow(
                id: item["id"].string ?? item["itemId"].string ?? UUID().uuidString,
                text: joined,
                requestId: item["source"]["rpcId"].string,
                preview: MessageQuotes.preview(joined),
                attachments: attachments
            )
        }
    }

    /// Local echoes still waiting: queued ones until the queue row arrives, the others until their message.
    /// One that is on screen as its bubble has nothing left to say here.
    var visiblePending: [PendingSubmission] {
        let inbox = projection("inbox")
        let queued = Set((inbox["next-turn"].array + inbox["next-step"].array).compactMap { $0["source"]["rpcId"].string })
        return pending.filter { !$0.showsBubble && (!queued.contains($0.id) || $0.placement == .transcript) }
    }

    /// The messages just sent that the timeline shows already.
    var bubbles: [PendingSubmission] { pending.filter(\.showsBubble) }

    var uploadsPending: Bool { attachments.contains { if case .ready = $0.upload { false } else { $0.upload != nil } } }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && quotes.isEmpty }
    /// Nothing the main button could send.
    var nothingToSend: Bool { isEmpty }

    func requestFocus() { focusRequest += 1 }

    // MARK: Draft (C-92)

    /// What a reference shows in the field, against what the engine reads: `@标题`, not `@[标题](dsh-session:…)`.
    private var mentions: [String: String] = [:]

    func addMention(title: String, raw: String) -> String {
        let token = "@\(title)"
        mentions[token] = raw
        return token
    }

    private func expandMentions(_ text: String) -> String {
        mentions.keys.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: mentions[$1] ?? $1) }
    }

    /// Text this long joins as a file (`addLongText`) instead of going into the input. The input
    /// grows with what it holds, and SwiftUI works its height out by laying all of it out on the
    /// main thread: two megabytes pasted held the app for 20 s, and 8 s on each key after.
    static let longTextLimit = 5_000
    /// A draft longer than this is neither kept nor put back. One pasted before `longTextLimit`
    /// held every launch on that layout for most of a minute, long enough for the system to end
    /// the app on a device: it could not be opened again.
    static let draftLimit = 100_000

    /// The stored draft, in the shape of the web's `dsh.conversation.<sid>` store:
    /// `{draft: {text, references, mentions, quotes}}`. It is kept by `DraftStore`.
    private static func loadDraft(_ sessionId: String) -> (text: String, quotes: [String], mentions: [String: String], dropped: Bool) {
        guard let data = DraftStore.shared.read(sessionId),
              let stored = try? JSONDecoder().decode(JSON.self, from: data) else { return ("", [], [:], false) }
        let text = stored["draft"]["text"].string ?? stored["draft"].string ?? ""
        guard text.utf16.count <= draftLimit else { return ("", [], [:], true) }
        let restored = DraftQuotes.restore(text: text, quotes: stored["draft"]["quotes"].array)
        return (restored.text, restored.quotes, stored["draft"]["mentions"].object.compactMapValues(\.string), false)
    }

    private func persistDraft() {
        guard !text.isEmpty || !quotes.isEmpty, text.utf16.count <= Self.draftLimit else { DraftStore.shared.write(nil, for: sessionId); return }
        let draft = DraftQuotes.store(quotes: quotes, text: text)
        var fields: [String: JSON] = ["text": .string(draft.text), "references": [], "mentions": .object(mentions.mapValues { .string($0) })]
        if !draft.quotes.isEmpty { fields["quotes"] = .array(draft.quotes) }
        if let data = try? JSONEncoder().encode(JSON.object(["draft": .object(fields)])) { DraftStore.shared.write(data, for: sessionId) }
    }

    // MARK: Quotes

    /// Quote text from the conversation into the draft (the web's `insertQuote`). Blank text is
    /// refused; the same text twice stays one quote.
    func addQuote(_ text: String) {
        let quote = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !quotes.contains(quote) { quotes.append(quote) }
        voice.mode = false
        requestFocus()
    }

    func removeQuote(at index: Int) {
        guard quotes.indices.contains(index) else { return }
        quotes.remove(at: index)
    }

    // MARK: Sending (C-20, C-91, C-94)

    enum Gesture { case preferred, queue, steer }

    /// Send the draft: a known `/command` line executes, everything else is an
    /// optimistic prompt (cleared at once, restored if the engine refuses it).
    /// `clearField` empties the text view at the moment the draft really goes
    /// (`clearFocusedTextInput`); a refused send must leave it alone.
    func submit(_ gesture: Gesture, context: ComposerContext, clearField: @escaping @MainActor () -> Void) {
        guard !executing, !isEmpty else { return }
        if uploadsPending {
            let failed = attachments.contains { if case .failed = $0.upload { true } else { false } }
            let reading = attachments.contains { if case .reading = $0.kind { true } else { false } }
            app.showToast(failed ? String(localized: "文件尚未上传成功，请重新添加后再试")
                : reading ? String(localized: "视频还在读取，请稍候再发送")
                : String(localized: "文件还在上传，请等待上传完成后发送"))
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/"), let (descriptor, line) = context.resolve(line: trimmed) {
            let bare = !trimmed.contains(where: \.isWhitespace)
            // A bare command or one taking arguments executes; arguments after an argument-less command make a message.
            if bare || descriptor.hint != nil {
                if !attachments.isEmpty && !descriptor.acceptsAttachments {
                    app.showToast(String(localized: "/\(String(trimmed.dropFirst().prefix { !$0.isWhitespace })) 不接受附件，请先移除附件"))
                    return
                }
                execute(expandMentions(line), draft: text, clearField: clearField)
                return
            }
        }
        let running = session?.running ?? false
        let steer: Bool = switch gesture {
        case .queue: false
        case .steer: running
        case .preferred: running && context.busyEnter == "steer"
        }
        clearField()
        sendMessage(text, quotes: quotes, steer: steer, running: running)
    }

    /// Send a written question at once (询问 AI). Whatever the reader had typed or attached in
    /// this conversation stays in the input; a refused question comes back there to send again.
    /// The returned task ends when the engine accepts the prompt or the send fails.
    @discardableResult
    func send(prompt: String, voiceCallId: String? = nil,
              idleReminder: (requestId: String, report: Task<Void, Never>)? = nil,
              after previous: Task<Void, Never>? = nil) -> Task<Void, Never> {
        let draft = text, kept = attachments
        attachments = []
        let submission = sendMessage(prompt, quotes: [], steer: false, running: session?.running ?? false,
                                     voiceCallId: voiceCallId, idleReminder: idleReminder, after: previous)
        text = draft
        attachments = kept
        return submission
    }

    /// Quotes keep their own place in the draft and join the text only here, the way the web
    /// serializes its quote nodes: what the echo shows is what the engine receives.
    @discardableResult
    private func sendMessage(_ draft: String, quotes sentQuotes: [String], steer: Bool, running: Bool,
                             voiceCallId: String? = nil,
                             idleReminder: (requestId: String, report: Task<Void, Never>)? = nil,
                             after previous: Task<Void, Never>? = nil) -> Task<Void, Never> {
        let trimmed = MessageQuotes.compose(quotes: sentQuotes, text: expandMentions(draft))
        let shown = MessageQuotes.compose(quotes: sentQuotes, text: draft)
        let sent = attachments
        let requestId = idleReminder?.requestId ?? UUID().uuidString.lowercased()
        let stored = sent.compactMap(\.stored)
        let submission = PendingSubmission(
            id: requestId, text: shown, attachments: sent.map(\.name),
            stored: stored.count == sent.count ? stored : nil,
            placement: running ? (steer ? .steering : .queued) : .transcript
        )
        // The engine stores a still of an animated image: the original is kept for the bubble.
        for attachment in sent {
            if case .image(_, let file, _) = attachment.kind, let id = attachment.stored?.attachmentId { SentAnimations.keep(file, for: id) }
        }
        if submission.showsBubble {
            bubbleIds.insert(requestId)
            // Its images show as they were picked until the stored copies are read.
            for attachment in sent {
                if case .image(_, _, let preview) = attachment.kind, let id = attachment.stored?.attachmentId { session?.keepPreview(preview, for: id) }
            }
            app.bubbleRises()
        }
        pending.append(submission)
        // Sending the restored text consumes the failures it held.
        if restoredText != nil { failedDrafts.removeAll(); restoredText = nil; restoredQuotes = [] }
        sendSeq += 1
        let seq = sendSeq
        text = ""
        // Written only when there is something to clear: an attachment is not comparable, so even an
        // empty list written over an empty one redraws everything that reads it.
        if !attachments.isEmpty { attachments = [] }
        if !sentQuotes.isEmpty { quotes = [] }
        return Task {
            do {
                guard let session else { throw CancellationError() }
                var content = try Self.content(for: sent)
                if !trimmed.isEmpty { content.append(["type": "text", "text": .string(trimmed)]) }
                await previous?.value
                // A quick answer can arrive while the app's question is still being reported.
                await idleReminder?.report.value
                try await session.prompt(content: content, steer: steer, requestId: requestId, voiceCallId: voiceCallId)
                ShareSuggestions.didSend(in: sessionId, app: app)
                mentions = [:]
                // The Host has the bytes now: the private copies are done with.
                for attachment in sent { attachment.removeCopy() }
                // A safety net: the message or its queue row normally retires the echo first.
                Task {
                    try? await Task.sleep(for: .seconds(30))
                    retire(requestId)
                }
            } catch is CancellationError where voiceCallId != nil {
                retire(requestId)
            } catch {
                retire(requestId)
                restoreFailed(seq: seq, draft: draft, quotes: sentQuotes, attachments: sent)
                Haptics.error()
                app.showToast(errorText(error))
            }
        }
    }

    /// Failed drafts come back in send order, joined by blank lines, only into an
    /// empty input (or one still holding the last restore); attachments always return.
    private func restoreFailed(seq: Int, draft: String, quotes failed: [String], attachments sent: [DraftAttachment]) {
        attachments = sent + attachments
        failedDrafts.append((seq, draft, failed))
        guard text.isEmpty || text == restoredText, quotes.isEmpty || quotes == restoredQuotes else { return }
        let ordered = failedDrafts.sorted { $0.seq < $1.seq }
        let joined = ordered.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        var restored: [String] = []
        for quote in ordered.flatMap(\.quotes) where !restored.contains(quote) { restored.append(quote) }
        text = joined
        quotes = restored
        restoredText = joined
        restoredQuotes = restored
    }

    /// Execute a command line (C-100). The draft stays until it is accepted, and comes
    /// back with a notice when the engine refuses it (C-91).
    private func execute(_ line: String, draft: String, clearField: @escaping @MainActor () -> Void) {
        let sent = attachments
        executing = true
        Task {
            defer { executing = false }
            do {
                guard let session else { return }
                // Commands take file receipts only: an image goes with the line, uploaded or not.
                let value = try await session.executeCommand(line, attachments: Self.content(for: sent, inlineImages: true))
                if value.isNull {
                    app.showToast(String(localized: "未知或格式不对的指令：\(line)"))
                    return
                }
                if !sent.isEmpty, value["result"]["kind"].string == "error" {
                    app.showToast(value["result"]["text"].string ?? String(localized: "指令执行失败"))
                    return
                }
                // The outcome renders as a command node in the timeline; the composer only clears.
                if text == draft { clearField(); text = "" } else if text.hasPrefix(draft) { text = String(text.dropFirst(draft.count)) }
                let sentIds = Set(sent.map(\.id))
                attachments.removeAll { sentIds.contains($0.id) }
                for attachment in sent { attachment.removeCopy() }
            } catch {
                Haptics.error()
                app.showToast(errorText(error))
            }
        }
    }

    /// C-112: `/plan` enters plan mode (it toggles nothing: with no argument it only turns it on), `/plan off` leaves.
    func setPlan(_ on: Bool) {
        guard !planSwitching, let session else { return }
        planSwitching = true
        Task {
            defer { planSwitching = false }
            let failure = on ? String(localized: "进入计划模式失败") : String(localized: "退出计划模式失败")
            do {
                if try await session.executeCommand(on ? "/plan" : "/plan off").isNull { app.showToast(failure) }
                session.refreshProjections()
            } catch {
                app.showToast(failure + "：" + errorText(error))
            }
        }
    }

    /// The switch shows the saved value, not the tap: the projection answers once the Host has it.
    func setTeam(_ on: Bool) {
        guard !teamSwitching, let session else { return }
        teamSwitching = true
        Task {
            defer { teamSwitching = false }
            do {
                try await app.client.call("agentTeams/setEnabled", ["agentId": .string(sessionId), "enabled": .bool(on)])
                session.refreshProjections()
            } catch {
                app.showToast(String(localized: "智能体团队协作的设置没有保存，请重试：\(errorText(error))"))
            }
        }
    }

    /// `/compact`: its outcome renders as a command node in the timeline (the workbench's 压缩上下文 does the same).
    func compact() {
        guard !compacting, let session else { return }
        compacting = true
        Task {
            defer { compacting = false }
            do {
                if try await session.executeCommand("/compact").isNull { app.showToast(String(localized: "未知或格式不对的指令：/compact")) }
                session.refreshProjections()
            } catch {
                app.showToast(errorText(error))
            }
        }
    }

    /// Run a bare command picked from the menu, in the background (the token is already consumed).
    func runDetached(_ line: String) {
        Task {
            do {
                guard let value = try await session?.executeCommand(line) else { return }
                if value.isNull { app.showToast(String(localized: "未知或格式不对的指令：\(line)")) }
            } catch {
                app.showToast(errorText(error))
            }
        }
    }

    /// The attachments as prompt content. An uploaded image is cited by its receipt, as a file
    /// is (the receipt of an image upload enters the message as that image); one that was not
    /// uploaded, and every image when `inlineImages`, sends its bytes.
    private static func content(for attachments: [DraftAttachment], inlineImages: Bool = false) throws -> [JSON] {
        try attachments.map { attachment in
            if case .image(let mediaType, let file, _) = attachment.kind, inlineImages || attachment.upload == nil {
                let data = try Data(contentsOf: file).base64EncodedString()
                return ["type": "image", "mediaType": .string(mediaType), "data": .string(data), "name": .string(attachment.name)]
            }
            guard case .ready(let receipt) = attachment.upload else {
                throw EngineError(code: "session/attachment-invalid", message: String(localized: "文件尚未上传成功，请重新添加后再试"), detail: ["details": ["reason": "FILE_NOT_STAGED"]])
            }
            return ["type": "file", "receiptId": .string(receipt)]
        }
    }

    /// The durable message (or a queue row, for the dock) arrived: drop the echo.
    func observe(_ event: JSON) {
        guard event["type"].string == "user/message" else { return }
        let source = event["data"]["source"]
        guard source["kind"].string == "user", let rpc = source["rpcId"].string ?? source["requestId"].string else { return }
        retire(rpc)
    }

    private func retire(_ requestId: String) {
        pending.removeAll { $0.id == requestId }
    }

    // MARK: Errors (C-85)

    /// The web's composer copy: a busy writer, an attachment the engine refused, else `message (code)`.
    func errorText(_ error: Error) -> String {
        guard let error = error as? EngineError, let code = error.code else { return error.localizedDescription }
        switch code {
        case "session/writer-held":
            return String(localized: "当前会话已被占用，可能是其他正在运行的 DSH 导致的（如其他 dsh web、桌面端），请退出其他正在运行的 DSH 后重试。")
        case "session/attachment-invalid", "subagent/attachment-invalid":
            return attachmentErrorText(reason: error.detail["details"]["reason"].string ?? "")
        case "session/agent-busy":
            // The engine's catch-all for prompts: the cause is only in `details.reason`.
            guard let reason = error.detail["details"]["reason"].string?.split(separator: "\n").first else { fallthrough }
            return "\(error.message): \(reason) (\(code))"
        default:
            return "\(error.message) (\(code))"
        }
    }

    func attachmentErrorText(reason: String) -> String {
        let limits = imageLimits
        switch reason {
        case "MODEL_DOES_NOT_SUPPORT_IMAGES": return String(localized: "当前模型不支持图片，请切换支持图片的模型")
        case "FILE_NOT_STAGED": return String(localized: "文件尚未上传成功，请重新添加后再试")
        case "IMAGE_TOO_MANY_PIXELS": return String(localized: "图片分辨率过大，请压缩后重试")
        case "IMAGE_DIMENSION_TOO_LARGE": return String(localized: "图片宽高不能超过 \(limits.maxImageDimension)px，请缩小后重试")
        case "INVALID_IMAGE", "IMAGE_TYPE_MISMATCH": return String(localized: "仅支持 PNG、JPG、WebP、GIF 格式的图片")
        case "TOO_MANY_IMAGES": return String(localized: "一条消息最多添加 \(limits.maxImagesPerMessage) 张图片")
        case "IMAGE_TOO_LARGE": return String(localized: "单张图片不能超过 \(ImageLimits.sizeText(limits.maxImageBytes))")
        case "IMAGES_TOO_LARGE": return String(localized: "图片总大小超过 \(ImageLimits.sizeText(limits.maxMessageImageBytes))，请移除部分图片")
        default: return String(localized: "图片发送失败（\(reason)），请重新添加图片后再试")
        }
    }

    // MARK: Queue (C-95)

    /// 「立即发送」 on a message queued for the next turn: DSH's steer. One the agent could no
    /// longer take (stopped, or already picked up) is silent.
    func steerQueued(_ id: String) async {
        do {
            try await session?.updateQueue(id, action: ["kind": "steer"])
        } catch {
            let code = (error as? EngineError)?.code
            if code == "session/steer-unavailable" || code == "session/queue-item-not-found" { return }
            app.showToast(String(localized: "插话发送失败，请重试。"))
        }
    }

    /// 「取消」 on a queued message: out of the queue and back into the input, ahead of whatever
    /// is being typed. Its attachments do not come back (they are stored blocks, not drafts).
    func withdrawQueued(_ row: QueueRow) async {
        do {
            try await session?.updateQueue(row.id, action: ["kind": "remove"])
        } catch {
            app.showToast(String(localized: "取消失败：这条消息可能已经开始发送。"))
            return
        }
        // Sent from here: its echo waits for a message that will not come now.
        if let request = row.requestId { retire(request) }
        if !row.text.isEmpty {
            text = text.isEmpty ? row.text : row.text + "\n" + text
        }
        if !row.attachments.isEmpty {
            app.showToast(String(localized: "附件没有放回输入框，需要的话重新添加。"))
        }
        requestFocus()
    }

    // MARK: Goal (C-121)

    /// Re-read whether the goal is armed (after projection changes, a run edge, `goal/activation-changed`).
    func refreshGoalActivation() async {
        guard let goal, goal.phase == "active" else { goalActivation = nil; return }
        guard let value = try? await app.client.call("goals/get", ["agentId": .string(sessionId)]),
              let id = value["id"].string else { return }
        goalActivation = (id, value["revision"].int ?? 0, value["activation"].string != "disarmed")
    }

    enum GoalAction { case pause, resume, clear, edit(String) }

    /// Run one goal action against the current goal; returns the error line on failure.
    func goalAction(_ action: GoalAction) async -> String? {
        guard let goal else { return String(localized: "no current goal to mutate (no-current-goal)") }
        let ref: JSON = ["id": .string(goal.id), "revision": .number(Double(goal.revision))]
        var args: [String: JSON] = ["agentId": .string(sessionId), "ref": ref]
        let method: String
        switch action {
        case .pause: method = "goals/pause"
        case .resume: method = "goals/resume"
        case .clear: method = "goals/clear"
        case .edit(let objective):
            method = "goals/edit"
            args["request"] = ["objective": .string(objective)]
        }
        do {
            let value = try await app.client.call(method, .object(args))
            if let id = value["id"].string, let activation = value["activation"].string {
                goalActivation = (id, value["revision"].int ?? 0, activation != "disarmed")
            }
            if case .clear = action { clearedGoalId = goal.id }
            session?.refreshProjections()
            return nil
        } catch {
            if let error = error as? EngineError { return "\(error.message) (\(error.code ?? ""))" }
            return error.localizedDescription
        }
    }

    // MARK: Attachments (C-104, C-105)

    /// Add a captured image, which has no file bytes of its own: encoded once as JPEG, then added as bytes.
    @discardableResult
    func addImage(_ image: UIImage, name: String? = nil) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return String(localized: "仅支持 PNG、JPG、WebP、GIF 格式的图片") }
        return addImage(data: data, name: name)
    }

    /// Add a picked image by its file bytes: sent as they are when the session accepts them,
    /// re-encoded only when the type (HEIC…) or a limit requires it (`DraftImage.prepare`).
    /// The bytes go to a file and from there to the Host at once, which scales the image down
    /// and stores it (the web's `uploadImage`); what stays in memory is the preview.
    /// Returns the refusal to show, if any.
    @discardableResult
    func addImage(data: Data, name: String? = nil) -> String? {
        let limits = imageLimits
        let images = attachments.filter(\.isImage)
        if images.count + 1 > limits.maxImagesPerMessage {
            return String(localized: "一条消息最多添加 \(limits.maxImagesPerMessage) 张图片")
        }
        let image: DraftImage
        switch DraftImage.prepare(data, name: name, index: images.count + 1, limits: limits) {
        case .success(let prepared): image = prepared
        case .failure(.tooLarge): return String(localized: "单张图片不能超过 \(ImageLimits.sizeText(limits.maxImageBytes))")
        case .failure(.unreadable): return String(localized: "仅支持 PNG、JPG、WebP、GIF 格式的图片")
        }
        if images.reduce(0, { $0 + $1.bytes }) + image.data.count > limits.maxMessageImageBytes {
            return String(localized: "图片总大小超过 \(ImageLimits.sizeText(limits.maxMessageImageBytes))，请移除部分图片")
        }
        let file: URL
        do {
            file = try PickedMovie.stage(image.data, name: image.name)
        } catch {
            return error.localizedDescription
        }
        let preview = DraftImage.preview(image.data).map { UIImage(cgImage: $0) } ?? UIImage()
        // Only an ordinary session stages image uploads (the web's rule): a subagent
        // continuation's images travel with the prompt.
        let uploads = session?.subagentAddress == nil
        let attachment = DraftAttachment(name: image.name, bytes: image.data.count, kind: .image(mediaType: image.mediaType, file: file, preview: preview),
                                         upload: uploads ? .uploading(loaded: 0, total: Int64(image.data.count)) : nil)
        attachments.append(attachment)
        if uploads { enqueueUpload(attachment.id) }
        return nil
    }

    var remainingImageSlots: Int { max(0, imageLimits.maxImagesPerMessage - attachments.filter(\.isImage).count) }

    /// Files from the Files app: images join as images, everything else uploads now.
    func addFiles(_ urls: [URL]) {
        var refusal: String?
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true, let data = try? Data(contentsOf: url), DraftImage.isImage(data) {
                if let reason = addImage(data: data, name: url.lastPathComponent) { refusal = reason }
                continue
            }
            // A private copy: the security-scoped URL may not outlive the picker, and retries reread it.
            do {
                addStagedFile(try PickedMovie.stage(url))
            } catch {
                refusal = error.localizedDescription
            }
        }
        if let refusal { app.showToast(refusal) }
    }

    /// Text over `longTextLimit` (a paste, a share), as a text file that uploads like any other.
    func addLongText(_ text: String) {
        do {
            addStagedFile(try PickedMovie.stage(Data(text.utf8), name: String(localized: "粘贴的文本") + ".txt"))
        } catch {
            app.showToast(error.localizedDescription)
        }
    }

    /// A file already copied into its own `uploads/` folder (`PickedMovie.stage`): it uploads
    /// now and joins as a plain file, the way the web sends a video (the engine keeps the bytes;
    /// nothing reads the frames).
    func addStagedFile(_ copy: URL) {
        let bytes = (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let attachment = DraftAttachment(name: copy.lastPathComponent, bytes: bytes, kind: .file(url: copy), upload: .uploading(loaded: 0, total: Int64(bytes)))
        attachments.append(attachment)
        enqueueUpload(attachment.id)
    }

    /// A video picked in the photo library: its card shows at once, saying how far the read
    /// got (a large or iCloud video can take a while), and turns into the file's card, which
    /// starts uploading, when the library hands the file over. `load` reports the library's
    /// progress as soon as the read starts.
    func readMovie(_ load: @escaping @MainActor (_ started: (Progress) -> Void) async throws -> URL) {
        let placeholder = DraftAttachment(name: String(localized: "视频"), bytes: 0, kind: .reading, upload: .reading(fraction: nil))
        attachments.append(placeholder)
        let id = placeholder.id
        Task {
            let watch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, let progress = self.reads[id], progress.totalUnitCount > 0,
                          let index = self.attachments.firstIndex(where: { $0.id == id }) else { continue }
                    let upload = DraftAttachment.Upload.reading(fraction: progress.fractionCompleted)
                    if self.attachments[index].upload != upload { self.attachments[index].upload = upload }
                }
            }
            defer {
                watch.cancel()
                reads[id] = nil
            }
            do {
                let url = try await load { reads[id] = $0 }
                guard let index = attachments.firstIndex(where: { $0.id == id }) else {
                    // Removed while it was read.
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                attachments[index].name = url.lastPathComponent
                attachments[index].bytes = bytes
                attachments[index].kind = .file(url: url)
                attachments[index].upload = .uploading(loaded: 0, total: Int64(bytes))
                enqueueUpload(id)
            } catch {
                // Gone already: the error is the cancel of its removal.
                guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
                attachments.remove(at: index)
                app.showToast(String(localized: "视频读取失败：\(error.localizedDescription)"))
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        reads[id]?.cancel()
        reads[id] = nil
        uploadTasks[id]?.cancel()
        uploadTasks[id] = nil
        uploadQueue.removeAll { $0 == id }
        attachments.first { $0.id == id }?.removeCopy()
        attachments.removeAll { $0.id == id }
    }

    func retryUpload(_ id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }), case .failed = attachments[index].upload else { return }
        attachments[index].upload = .uploading(loaded: 0, total: Int64(attachments[index].bytes))
        enqueueUpload(id)
    }

    private func enqueueUpload(_ id: UUID) {
        uploadQueue.append(id)
        pumpUploads()
    }

    /// Start queued uploads until the concurrency limit is used (FIFO).
    private func pumpUploads() {
        while activeUploads < Self.maxConcurrentFileUploads, !uploadQueue.isEmpty {
            let id = uploadQueue.removeFirst()
            guard let attachment = attachments.first(where: { $0.id == id }), let url = attachment.file else { continue }
            let mediaType: String? = if case .image(let mediaType, _, _) = attachment.kind { mediaType } else { nil }
            activeUploads += 1
            uploadTasks[id] = Task {
                var outcome: DraftAttachment.Upload?
                var stored: Attachment?
                do {
                    let reply = try await upload(url, name: attachment.name, mediaType: mediaType) { [weak self] sent, total in
                        Task { @MainActor in
                            guard let self, let index = self.attachments.firstIndex(where: { $0.id == id }),
                                  case .uploading = self.attachments[index].upload else { return }
                            self.attachments[index].upload = .uploading(loaded: sent, total: total > 0 ? total : nil)
                        }
                    }
                    outcome = .ready(receiptId: reply.receipt)
                    stored = reply.stored
                } catch let error as EngineError where mediaType != nil && error.code == "session/attachment-invalid" && !Task.isCancelled {
                    // The Host looked at the image and will not have it (too large, not an image it
                    // reads…): the same bytes cannot go through again, so it leaves with the reason.
                    uploadTasks[id] = nil
                    removeAttachment(id)
                    app.showToast(errorText(error))
                } catch {
                    outcome = .failed(error.localizedDescription)
                }
                if !Task.isCancelled, let outcome, let index = attachments.firstIndex(where: { $0.id == id }) {
                    attachments[index].upload = outcome
                    attachments[index].stored = stored
                }
                uploadTasks[id] = nil
                activeUploads -= 1
                pumpUploads()
            }
        }
    }

    /// `POST /api/session/uploadFileBinary?sessionId=&name=` with the raw bytes (the web's
    /// primary upload path); the reply is a bare `{ok, value: {receiptId, file}}` without the RPC envelope.
    /// With `mediaType` the Host takes the bytes as a prompt image: it validates, scales down
    /// and stores it then, and the reply's value carries `image` in place of `file`. Either is
    /// the reference the message will carry, returned with the receipt.
    private func upload(_ file: URL, name: String, mediaType: String?, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (receipt: String, stored: Attachment?) {
        let client = app.client
        var components = URLComponents(url: client.origin.appendingPathComponent("api/session/uploadFileBinary"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionId), URLQueryItem(name: "name", value: name)]
        if let mediaType { components.queryItems?.append(URLQueryItem(name: "mediaType", value: mediaType)) }
        // URLSearchParams reads `+` as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = client.request(components.url!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        let (data, response) = try await client.session.upload(for: request, fromFile: file, delegate: UploadProgress(progress))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let reply = try? JSONDecoder().decode(JSON.self, from: data) else {
            throw EngineError(code: "HTTP_\(status)", message: String(localized: "上传失败（HTTP \(status)）"), detail: .null)
        }
        if reply["ok"].bool == true, let receipt = reply["value"]["receiptId"].string {
            let value = reply["value"]
            let stored: Attachment? = if !value["image"].isNull {
                Attachment(block: ["type": "image", "attachment": value["image"]])
            } else if !value["file"].isNull {
                Attachment(block: ["type": "file", "attachment": value["file"]])
            } else {
                nil
            }
            return (receipt, stored)
        }
        throw EngineError(code: reply["error"]["code"].string, message: reply["error"]["message"].string ?? String(localized: "上传失败"), detail: reply["error"])
    }
}

/// Upload progress for one task (the engine client's session delegate handles redirects only).
private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let handler: @Sendable (Int64, Int64) -> Void
    init(_ handler: @escaping @Sendable (Int64, Int64) -> Void) { self.handler = handler }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        handler(totalBytesSent, totalBytesExpectedToSend)
    }
}
