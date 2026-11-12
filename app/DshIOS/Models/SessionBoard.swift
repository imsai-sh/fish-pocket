import Foundation

/// Where each top-level session stands, for the surfaces that list sessions outside
/// the app (widgets, the watch). A subagent's approval or question shows on the
/// session it serves. Sessions that are neither waiting nor running have no entry.
struct SessionBoard {
    enum Phase { case approval, question, running }

    struct Entry {
        var phase: Phase
        /// The approval's reason, or the open question.
        var detail: String?
        /// The approval the entry stands for (`eventId`, and the agent it came from).
        var approval: (eventId: String, agentId: String)?
    }

    private(set) var entries: [String: Entry] = [:]

    @MainActor
    init(_ app: AppModel) {
        func root(_ id: String) -> String {
            var id = id
            for _ in 0..<8 {
                guard let session = app.sessions[id], session.isSubagent, let parent = session.parentId else { break }
                id = parent
            }
            return id
        }

        for (agentId, pending) in app.approvals.sorted(by: { $0.key < $1.key }) {
            guard let approval = pending.first else { continue }
            let id = root(agentId)
            guard entries[id] == nil else { continue }
            let reason = approval.reason?.isEmpty == false ? approval.reason! : String(localized: "工具 \(approval.toolName) 请求越权执行")
            entries[id] = Entry(phase: .approval, detail: reason, approval: (approval.id, agentId))
        }
        for id in app.sessions.keys.sorted() where app.isWaiting(id) {
            let owner = root(id)
            guard entries[owner] == nil else { continue }
            let question = app.control[id]?["userQuestions"]?["active"].array.first?["questions"].array.first?["question"].string
                ?? app.questionRequests[id]?.first?.questions.first?.question
            entries[owner] = Entry(phase: .question, detail: question)
        }
        for session in app.sessions.values where session.running {
            let id = root(session.id)
            if entries[id] == nil { entries[id] = Entry(phase: .running) }
        }
    }

    /// The sessions a list outside the app shows: top-level, not blank, not archived.
    @MainActor
    static func listed(in app: AppModel) -> [SessionSummary] {
        app.sessions.values.filter { !$0.isSubagent && !$0.blank && !app.isArchived($0.id) }
    }
}

/// The sessions on a computer that the phone answers for (`RemoteSession.followed`), as the
/// same surfaces list them beside the phone's own.
extension SessionBoard {
    struct Away {
        /// The session as the shell names it (`remote:<id>`): what a link or an answer carries.
        let id: String
        let title: String
        /// nil while it neither waits nor works.
        let phase: Phase?
        /// What it waits with.
        let detail: String?
        /// The approval one tap answers either way; nil where an answer takes more than that.
        let approval: (eventId: String, agentId: String)?
        let updatedAt: Date
    }

    @MainActor
    static func away(in app: AppModel) -> [Away] {
        let remote = app.remote
        return remote.listed().filter(\.followed).map { session in
            let id = RemoteStore.selection(session.id)
            let request = session.waiting ? remote.requests[session.id] : nil
            // A request not read yet is taken for an approval: that is what a session waits with, nearly always.
            let phase: Phase? = !session.needsAttention ? nil
                : !session.waiting ? .running
                : request?.isApproval == false ? .question : .approval
            return Away(id: id, title: session.displayTitle, phase: phase, detail: request?.summary,
                        approval: request?.quickAnswers == nil ? nil : request.map { ($0.id, id) },
                        updatedAt: session.sortAt)
        }
    }
}
