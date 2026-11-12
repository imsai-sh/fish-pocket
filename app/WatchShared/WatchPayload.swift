import Foundation

/// What the watch app shows, sent by the iPhone app over WatchConnectivity.
///
/// The engine runs in the iPhone app's process, so the watch has nothing of its own
/// to ask: it draws the last snapshot the phone sent (`WatchLink`) and sends back
/// the few things the user can do from the wrist (`WatchCommand`).
/// Compiled into the iPhone app and the watch app.
struct WatchSnapshot: Codable, Equatable {
    enum Phase: String, Codable {
        case approval, question, running, idle

        /// Waiting on the user.
        var waiting: Bool { self == .approval || self == .question }
        var active: Bool { self != .idle }
    }

    /// The tool approval 允许 / 拒绝 answer.
    struct Approval: Codable, Hashable {
        var eventId: String
        var agentId: String
    }

    struct Session: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var phase: Phase
        /// The approval's command or reason, or the open question.
        var detail: String?
        var approval: Approval?
        /// Running since (as far as the phone saw); the row counts up from it.
        var since: Date?
        var updatedAt: Date
    }

    /// A turn that ended while the user was not looking at it on the phone.
    struct Completion: Codable, Hashable, Identifiable {
        var id: String
        var sessionId: String
        var title: String
        var at: Date
    }

    /// When the phone last wrote or confirmed this. It rewrites it while work runs,
    /// so an old one with active sessions means the phone app is no longer running.
    var writtenAt: Date
    /// Waiting first, then running, then the most recently updated idle ones.
    var sessions: [Session]
    /// The account balance as the phone words it; nil when signed out or not read yet.
    var balance: String?
    /// Kept until the watch reports them seen.
    var completions: [Completion]

    /// Past this, active sessions read as 状态未知.
    static let staleAfter: TimeInterval = 30 * 60

    func isStale(at date: Date) -> Bool {
        sessions.contains(where: \.phase.active) && date.timeIntervalSince(writtenAt) > Self.staleAfter
    }

    var waiting: [Session] { sessions.filter(\.phase.waiting) }
    var running: [Session] { sessions.filter { $0.phase == .running } }
}

/// What the wrist can do. Every command is answered with the snapshot as it stands afterwards.
enum WatchCommand: Codable, Equatable {
    /// Nothing to do: just the snapshot.
    case refresh
    case answer(approval: WatchSnapshot.Approval, allow: Bool)
    /// These completions were shown; the phone drops them.
    case seen(completions: [String])
}

/// The dictionaries WatchConnectivity carries: one JSON blob under one key.
enum WatchWire {
    private static let snapshotKey = "snapshot"
    private static let commandKey = "command"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func pack(_ snapshot: WatchSnapshot) -> [String: Any] {
        (try? encoder.encode(snapshot)).map { [snapshotKey: $0] } ?? [:]
    }

    static func pack(_ command: WatchCommand) -> [String: Any] {
        (try? encoder.encode(command)).map { [commandKey: $0] } ?? [:]
    }

    static func snapshot(in message: [String: Any]) -> WatchSnapshot? {
        (message[snapshotKey] as? Data).flatMap { try? decoder.decode(WatchSnapshot.self, from: $0) }
    }

    static func command(in message: [String: Any]) -> WatchCommand? {
        (message[commandKey] as? Data).flatMap { try? decoder.decode(WatchCommand.self, from: $0) }
    }
}
