import Foundation

/// A file a remote message carries; its bytes come from the server on demand.
struct RemoteAttachment: Identifiable, Hashable {
    var id: String
    var name: String
    var mediaType: String
    /// Where the server serves it, relative to the server.
    var link: String?
    /// Bytes already here: a message this phone just sent.
    var data: Data?

    var isImage: Bool { mediaType.hasPrefix("image/") }

    init?(_ json: JSON) {
        guard let id = json["fileId"].string ?? json["id"].string ?? json["name"].string else { return nil }
        self.id = id
        name = json["name"].string ?? String(localized: "附件")
        mediaType = json["mediaType"].string ?? json["mimeType"].string ?? "application/octet-stream"
        link = json["openUrl"].string ?? json["downloadUrl"].string
    }

    init(upload: RemoteUpload, id: String) {
        self.id = id
        name = upload.name
        mediaType = upload.mediaType
        data = upload.data
    }
}

/// One assistant turn of a remote session, in the blocks the conversation's own views draw.
struct RemoteTurn: Identifiable, Hashable {
    let id: String
    var blocks: [AssistantBlock] = []
    /// How many trailing blocks are still being written.
    var liveCount = 0
    var startedAt: Date?
    var endedAt: Date?
    /// `interrupted` or `error` when it did not end well.
    var closed: String?
    var inProgress = false
    /// The agent's own id for the turn, where its records carry one.
    var turnId: String?
}

enum RemoteRow: Identifiable, Hashable {
    case user(id: String, text: String, attachments: [RemoteAttachment], delivery: RemotePendingMessage.Delivery?)
    case turn(RemoteTurn)
    case notice(id: String, text: String, isError: Bool)

    var id: String {
        switch self {
        case .user(let id, _, _, _): "u-\(id)"
        case .turn(let turn): "t-\(turn.id)"
        case .notice(let id, _, _): "n-\(id)"
        }
    }
}

/// Turns a remote session's records into rows. Agents Anywhere normalises what Codex, Claude Code
/// and DSH write into one vocabulary (`command`, `file_change`, `web_search`, `mcp`, `agent_call`…);
/// here that becomes the tool names this app already has rows and cards for, so a remote turn
/// reads like a local one. A record is mapped once per version: a streamed reply re-maps only itself.
struct RemoteTimelineBuilder {
    private enum Piece: Hashable {
        case user(text: String, attachments: [RemoteAttachment])
        case blocks([AssistantBlock], streaming: Bool)
        case notice(text: String, isError: Bool, reconnect: Bool)
        case turnStart
        case turnEnd(closed: String?)
        case hidden

        /// A retry notice that the next one replaces.
        var isReconnect: Bool {
            if case .notice(_, _, true) = self { return true }
            return false
        }
    }

    private var cache: [String: (item: RemoteItem, piece: Piece)] = [:]

    mutating func rows(items: [RemoteItem], busy: Bool, pending: [RemotePendingMessage]) -> [RemoteRow] {
        var rows: [RemoteRow] = []
        var turn: RemoteTurn?
        var next: [String: (item: RemoteItem, piece: Piece)] = [:]
        next.reserveCapacity(items.count)
        var echoed: Set<String> = []

        func close(_ closed: String? = nil, at date: Date? = nil) {
            guard var current = turn else { return }
            current.closed = closed ?? current.closed
            current.endedAt = date ?? current.endedAt
            rows.append(.turn(current))
            turn = nil
        }

        for item in items {
            let piece: Piece
            if let cached = cache[item.id], cached.item == item { piece = cached.piece } else { piece = Self.piece(item) }
            next[item.id] = (item, piece)
            switch piece {
            case .hidden:
                continue
            case .user(let text, let attachments):
                close()
                if let client = item.source["clientMessageId"].string { echoed.insert(client) }
                rows.append(.user(id: item.id, text: text, attachments: attachments, delivery: nil))
            case .turnStart:
                close()
                turn = RemoteTurn(id: item.id, startedAt: item.createdAt, turnId: item.turnId)
            case .turnEnd(let closed):
                if turn == nil, closed != nil { turn = RemoteTurn(id: item.id, startedAt: item.createdAt, turnId: item.turnId) }
                close(closed, at: item.completedAt ?? item.createdAt)
            case .notice(let text, let isError, let reconnect):
                close()
                // A run of reconnect attempts reads as its latest one.
                if reconnect, case .notice(let id, _, _)? = rows.last, next[id]?.piece.isReconnect == true { rows.removeLast() }
                rows.append(.notice(id: item.id, text: text, isError: isError))
            case .blocks(let blocks, let streaming):
                // Servers keep no turn markers in the timeline: a turn runs from the first record
                // after a user message to the next one, or to a record of another turn.
                if let open = turn?.turnId, let next = item.turnId, open != next { close() }
                var current = turn ?? RemoteTurn(id: item.id, startedAt: item.createdAt, turnId: item.turnId)
                if current.turnId == nil { current.turnId = item.turnId }
                current.blocks += blocks
                current.liveCount = streaming ? current.liveCount + blocks.count : 0
                current.endedAt = item.completedAt ?? item.createdAt
                turn = current
            }
        }
        cache = next

        // The last turn is the one being worked on while the agent is busy.
        if var current = turn {
            if busy { current.inProgress = true; current.endedAt = nil } else { current.liveCount = 0 }
            rows.append(.turn(current))
        }
        for message in pending where !echoed.contains(message.id) {
            rows.append(.user(id: "pending-\(message.id)", text: message.text,
                              attachments: message.attachments.enumerated().map { RemoteAttachment(upload: $0.element, id: "\(message.id)-\($0.offset)") },
                              delivery: message.delivery))
        }
        return rows
    }

    /// Client ids of the sent messages the timeline now carries.
    static func echoed(_ items: [RemoteItem]) -> Set<String> {
        Set(items.compactMap { $0.role == "user" ? $0.source["clientMessageId"].string : nil })
    }

    // MARK: Records

    private static func piece(_ item: RemoteItem) -> Piece {
        guard item.status != "hidden" else { return .hidden }
        let content = item.content
        switch item.type {
        case "turn.start":
            return .turnStart
        case "turn.end":
            return .turnEnd(closed: closed(item))
        case "message":
            let text = messageText(content)
            switch item.role {
            case "user":
                let attachments = content["attachments"].array.compactMap(RemoteAttachment.init)
                return text.isEmpty && attachments.isEmpty ? .hidden : .user(text: text, attachments: attachments)
            case "assistant", nil:
                if text.isEmpty { return .hidden }
                return .blocks([.text(id: item.id, text: text)], streaming: item.active)
            default:
                return text.isEmpty ? .hidden : .notice(text: String(text.prefix(400)), isError: false, reconnect: false)
            }
        case "tool", "file_change":
            return .blocks(toolCalls(item).map(AssistantBlock.tool), streaming: false)
        case "artifact":
            switch content["kind"].string {
            case "diff": return .hidden
            case "file_change": return .blocks(toolCalls(item).map(AssistantBlock.tool), streaming: false)
            default:
                guard let path = first(content["path"], content["filePath"], content["title"], content["name"]) else { return .hidden }
                return .notice(text: String(localized: "生成了文件 \((path as NSString).lastPathComponent)"), isError: false, reconnect: false)
            }
        default:
            if item.isReasoning {
                let text = reasoningText(content)
                if text.isEmpty, !item.active { return .hidden }
                return .blocks([.reasoning(id: item.id, text: text)], streaming: item.active)
            }
            guard ["marker", "system"].contains(item.type) else { return .hidden }
            return marker(item)
        }
    }

    private static func closed(_ item: RemoteItem) -> String? {
        if item.failed { return "error" }
        return item.stopped ? "interrupted" : nil
    }

    private static func marker(_ item: RemoteItem) -> Piece {
        let content = item.content
        switch content["kind"].string {
        case "turn_start": return .turnStart
        case "turn_end": return .turnEnd(closed: closed(item))
        default: break
        }
        if content["code"].string == "model_request_retry" {
            let text: String
            switch content["state"].string {
            case "completed": text = String(localized: "重试结束，模型已恢复响应。")
            case "interrupted": text = String(localized: "已取消模型请求重试。")
            case "failed": text = String(localized: "模型请求重试后仍失败。")
            default:
                let attempt = content["attempt"].int ?? 1
                let reason = content["reason"].string == "rate_limit" ? String(localized: "模型服务暂时繁忙，正在重试") : String(localized: "模型服务暂时不可用，正在重试")
                text = content["maxAttempts"].int.map { String(localized: "\(reason)（第 \(attempt)/\($0) 次）") } ?? String(localized: "\(reason)（第 \(attempt) 次）")
            }
            return .notice(text: text, isError: content["state"].string == "failed", reconnect: content["state"].isNull)
        }
        if content["kind"].string == "compact" {
            let running = ["started", "running", "inProgress"].contains(content["state"].string ?? "") || item.active
            let failed = item.failed || content["state"].string == "failed"
            let text = failed ? String(localized: "上下文压缩失败") : running ? String(localized: "正在压缩上下文") : String(localized: "上下文已压缩")
            return .notice(text: text, isError: failed, reconnect: false)
        }
        let message = item.type == "marker"
            ? first(content["label"], content["title"], content["text"])
            : first(content["text"], content["message"], content["rawText"], content["details"]["error"]["message"], content["title"])
        guard let message else { return .hidden }
        let isError = item.failed || content["kind"].string == "error"
        return .notice(text: String(message.prefix(400)), isError: isError, reconnect: isError && message.hasPrefix("Reconnecting"))
    }

    /// The reply without the attachment notes the connector appends for the model.
    private static func messageText(_ content: JSON) -> String {
        let text = first(content["text"], content["content"], content["message"], content["rawText"]) ?? ""
        guard text.contains("\n\n[") else { return text }
        let cut = ["\n\n[Attached file: ", "\n\n[Failed to load attachment ", "\n\n[Attachments dropped "].compactMap { text.range(of: $0)?.lowerBound }.min()
        return cut.map { String(text[..<$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? text
    }

    private static func reasoningText(_ content: JSON) -> String {
        let summaries = content["summaries"].array.compactMap { $0["text"].string }.filter { !$0.isEmpty }
        if !summaries.isEmpty { return summaries.joined(separator: "\n\n") }
        return first(content["rawText"], content["text"], content["summary"]) ?? ""
    }

    private static func first(_ values: JSON...) -> String? {
        values.lazy.compactMap(\.string).first { !$0.isEmpty }
    }

    // MARK: Tool calls

    /// Claude Code's own tool names, as the names this app's rows and cards know.
    private static let known: [String: String] = [
        "bash": "bash", "read": "read", "write": "write", "edit": "edit", "multiedit": "multi_edit", "glob": "glob", "grep": "grep",
        "ls": "ls", "webfetch": "web_fetch", "websearch": "web_search", "todowrite": "todo_write", "skill": "skill",
        "exitplanmode": "exit_plan_mode", "task": "subagent", "agent": "subagent", "shell": "bash", "exec_command": "bash",
    ]

    static func toolCalls(_ item: RemoteItem) -> [ToolCall] {
        let content = item.content
        let kind = content["kind"].string ?? (item.type == "tool" ? "tool" : "file_change")
        let input = content["input"]
        let toolName = first(content["toolName"], content["name"], content["tool"], content["title"])

        func call(_ name: String, _ arguments: JSON, id: String = item.id) -> ToolCall {
            var call = ToolCall(id: id, name: name, arguments: arguments, rawArguments: "")
            // The previous list is not looked up here: the card shows the list as it stands.
            call.historyComplete = false
            guard !item.active else { return call }
            call.result = output(content) ?? ""
            call.isError = item.failed || content["isError"].bool == true || (content["exitCode"].int ?? 0) != 0
            if item.stopped { call.errorCode = "interrupted" }
            return call
        }

        switch kind {
        case "command":
            var arguments: [String: JSON] = ["command": .string(command(content["command"]) ?? command(input["command"]) ?? command(input["cmd"]) ?? "")]
            if let description = content["description"].string ?? input["description"].string, !description.isEmpty, .string(description) != arguments["command"] {
                arguments["description"] = .string(description)
            }
            if let cwd = content["cwd"].string, !cwd.isEmpty { arguments["workdir"] = .string(cwd) }
            return [call("bash", .object(arguments))]
        case "file_change":
            return fileChanges(item, toolName: toolName, make: call)
        case "web_search":
            if let url = first(content["url"], input["url"]) { return [call("web_fetch", ["url": .string(url)])] }
            return [call("web_search", ["query": .string(first(content["query"], input["query"]) ?? "")])]
        case "mcp":
            let server = first(content["server"], input["server"]) ?? "mcp"
            let tool = first(content["tool"], input["tool"], content["title"]) ?? "tool"
            return [call("mcp__\(server)__\(tool)", content["arguments"].nonNull ?? input)]
        case "agent_call":
            let name = switch content["action"].string {
            case "wait": "wait_agent"
            case "send_input": "send_message"
            case "close": "interrupt_agent"
            default: "subagent"
            }
            var arguments: [String: JSON] = [:]
            if let description = first(content["description"], content["title"], content["agentType"]) { arguments["description"] = .string(description) }
            if let prompt = content["prompt"].string { arguments["prompt"] = .string(prompt) }
            return [call(name, .object(arguments))]
        default:
            let raw = toolName ?? kind
            let name = known[raw.lowercased()] ?? raw
            let arguments = input.object.isEmpty ? content["arguments"] : input
            return [call(name, arguments.object.isEmpty ? .object([:]) : arguments)]
        }
    }

    private static func output(_ content: JSON) -> String? {
        if let text = first(content["output"], content["outputText"], content["outputPreview"], content["error"]) { return text }
        for key in ["output", "result"] {
            guard let value = content[key].nonNull, value.string == nil else { continue }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(value) { return String(decoding: data, as: UTF8.self) }
        }
        return nil
    }

    private static func command(_ value: JSON) -> String? {
        if let text = value.string { return text.isEmpty ? nil : text }
        let parts = value.array.compactMap(\.string)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// One call per file. Claude's edits keep their own arguments; a patch (Codex) is split into
    /// what it removed and what it put there, which is all the diff card needs.
    private static func fileChanges(_ item: RemoteItem, toolName: String?, make: (String, JSON, String) -> ToolCall) -> [ToolCall] {
        let content = item.content, input = content["input"]
        if let path = input["file_path"].string ?? input["notebook_path"].string {
            switch toolName {
            case "Write":
                return [make("write", ["file_path": .string(path), "content": input["content"]], item.id)]
            case "Edit":
                return [make("edit", ["file_path": .string(path), "old_string": input["old_string"], "new_string": input["new_string"]], item.id)]
            case "MultiEdit":
                return [make("multi_edit", ["file_path": .string(path), "edits": input["edits"]], item.id)]
            default:
                break
            }
        }
        var changes = content["changes"].array
        if changes.isEmpty {
            // Codex also writes them as `{path: change}`.
            changes = content["changes"].object.keys.sorted().map { path in
                var fields = content["changes"][path].object
                if fields["path"] == nil { fields["path"] = .string(path) }
                return .object(fields)
            }
        }
        if changes.isEmpty, path(content) != nil { changes = [content] }
        return changes.enumerated().map { index, change in
            let id = changes.count == 1 ? item.id : "\(item.id)#\(index)"
            let file = path(change) ?? ""
            let text = (first(change["diff"], change["patch"], change["content"]) ?? "")
                .replacingOccurrences(of: "\r\n", with: "\n")
            let action = (first(change["kind"]["type"], change["action"], change["type"], change["kind"]) ?? "").lowercased()
            let adding = ["add", "added", "create", "created"].contains(action)
            let deleting = ["delete", "deleted", "remove", "removed"].contains(action)
            if adding, !isPatch(text) {
                return make("write", ["file_path": .string(file), "content": .string(text)], id)
            }
            let hunks = isPatch(text) ? Self.hunks(text) : deleting ? [(text, "")] : []
            var call = make("edit", [
                "file_path": .string(file),
                "old_string": .string(hunks.map(\.0).joined(separator: "\n")),
                "new_string": .string(hunks.map(\.1).joined(separator: "\n")),
            ], id)
            if !hunks.isEmpty {
                call.meta = ["diffs": .array(hunks.map { ["oldText": .string($0.0), "newText": .string($0.1)] })]
            }
            return call
        }
    }

    private static func path(_ value: JSON) -> String? {
        first(value["path"], value["filePath"], value["file"], value["uri"])
    }

    private static func isPatch(_ text: String) -> Bool {
        text.hasPrefix("@@") || text.contains("\n@@") || (text.contains("--- ") && text.contains("+++ "))
    }

    /// The before and after of each hunk of a unified diff (or an `apply_patch` body).
    private static func hunks(_ patch: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var old: [String] = [], new: [String] = []
        func flush() {
            if !old.isEmpty || !new.isEmpty { result.append((old.joined(separator: "\n"), new.joined(separator: "\n"))) }
            old = []
            new = []
        }
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("@@") { flush(); continue }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("*** ") || line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("\\ ") { continue }
            if line.hasPrefix("+") { new.append(String(line.dropFirst())) }
            else if line.hasPrefix("-") { old.append(String(line.dropFirst())) }
            else {
                let context = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                old.append(context)
                new.append(context)
            }
        }
        flush()
        return result
    }
}
