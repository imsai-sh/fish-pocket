import Foundation
import Observation
import SwiftUI
import WatchConnectivity

/// Keeps the watch app in step with the phone: sends it the snapshot it draws
/// (`WatchSnapshot`) whenever what it shows changes, and carries out what the
/// wrist sends back (`WatchCommand`). The sessions on a computer that the phone
/// answers for are in it with the phone's own, and answered the same way.
///
/// The snapshot travels as the application context, so the watch gets the latest
/// one whenever it next wakes; every command is also answered with it.
@MainActor
final class WatchLink: NSObject {
    static let shared = WatchLink()

    /// The watch lists this many sessions.
    private static let limit = 8
    private static let debounce = Duration.milliseconds(500)
    /// Well inside `WatchSnapshot.staleAfter`.
    private static let heartbeat = Duration.seconds(10 * 60)
    /// The session list briefly reads idle between a prompt and its turn: a turn has
    /// ended only once its session stayed idle this long.
    private static let settle = Duration.seconds(5)
    /// A completion nobody looked at is dropped after this.
    private static let completionLife: TimeInterval = 30 * 60

    private weak var app: AppModel?
    /// The content last sent, `writtenAt` aside.
    private var sent: WatchSnapshot?
    private var wanted: WatchSnapshot?
    /// When each session was first seen running in this run of the app.
    private var runningSince: [String: Date] = [:]
    /// Each listed session's phase as last derived.
    private var phases: [String: WatchSnapshot.Phase] = [:]
    private var completions: [WatchSnapshot.Completion] = []
    /// Sessions that just left `running`, waiting out `settle`.
    private var settling: [String: Task<Void, Never>] = [:]
    private var pendingSend: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var onScreen = true
    /// The observation in force: an older one (a previous engine connection) does not renew itself.
    private var tracking = 0

    private override init() {}

    /// Called at launch, before any window: a command from the watch can start the app in the background.
    func activate() {
        guard WCSession.isSupported(), WCSession.default.delegate == nil else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func attach(_ app: AppModel) {
        self.app = app
        phases = [:]
        tracking += 1
        observe(tracking)
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        onScreen = phase == .active
        if onScreen { refresh() }
    }

    /// Re-derive on every change of what the snapshot reads (sessions, approvals, projections, balance).
    private func observe(_ token: Int) {
        guard let app, token == tracking else { return }
        let next = withObservationTracking { Self.snapshot(of: app) } onChange: { [weak self] in
            Task { @MainActor in self?.observe(token) }
        }
        apply(next)
    }

    /// Something outside the model changed (a completion, the scene phase, the link to the watch).
    private func refresh() {
        guard let app else { return }
        apply(Self.snapshot(of: app))
    }

    private func apply(_ snapshot: WatchSnapshot) {
        var next = snapshot
        let now = Date.now

        let running = Set(next.running.map(\.id))
        runningSince = runningSince.filter { running.contains($0.key) }
        for id in running where runningSince[id] == nil { runningSince[id] = now }
        next.sessions = next.sessions.map { session in
            var session = session
            session.since = runningSince[session.id]
            return session
        }

        noteCompletions(in: next, at: now)
        next.completions = completions
        wanted = next
        guard next != sent else { return }
        pendingSend?.cancel()
        pendingSend = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.send()
        }
    }

    /// A session that ran and has stayed idle for `settle` has finished a turn, unless
    /// the user is looking at it on the phone. One that is active again, or that they
    /// have opened, no longer has a completion to report.
    private func noteCompletions(in snapshot: WatchSnapshot, at now: Date) {
        let current = onScreen ? app?.currentSession : nil
        for session in snapshot.sessions {
            let old = phases[session.id]
            phases[session.id] = session.phase
            if session.phase.active {
                settling.removeValue(forKey: session.id)?.cancel()
            } else if old == .running, settling[session.id] == nil {
                let id = session.id
                settling[id] = Task { [weak self] in
                    try? await Task.sleep(for: Self.settle)
                    guard !Task.isCancelled else { return }
                    self?.settled(id)
                }
            }
        }
        let active = Set(snapshot.sessions.filter(\.phase.active).map(\.id))
        completions.removeAll { active.contains($0.sessionId) || $0.sessionId == current || now.timeIntervalSince($0.at) > Self.completionLife }
    }

    private func settled(_ id: String) {
        settling[id] = nil
        guard let app, phases[id] == .idle else { return }
        guard !(onScreen && app.currentSession == id) else { return }
        completions.removeAll { $0.sessionId == id }
        let title = RemoteStore.sessionId(of: id).map { app.remote.sessions[$0]?.displayTitle ?? String(localized: "新会话") } ?? app.title(of: id)
        completions.append(.init(id: UUID().uuidString, sessionId: id, title: title, at: .now))
        refresh()
    }

    private func send() {
        guard var snapshot = wanted else { return }
        let content = snapshot
        snapshot.writtenAt = .now
        keepConfirming(snapshot.sessions.contains(where: \.phase.active))
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        // Not delivered (no watch app yet): `sent` stays behind, so the next change or activation sends again.
        guard (try? WCSession.default.updateApplicationContext(WatchWire.pack(snapshot))) != nil else { return }
        sent = content
    }

    /// While sessions are active the snapshot is confirmed now and then; idle needs no confirming.
    private func keepConfirming(_ on: Bool) {
        guard on else {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            return
        }
        guard heartbeatTask == nil else { return }
        // `send` cancels it once nothing is active.
        heartbeatTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.heartbeat)
                guard !Task.isCancelled, let self else { return }
                self.send()
            }
        }
    }

    /// Carry out a command and answer with the snapshot as it stands afterwards
    /// (empty when the engine is not up: the watch then asks for the app to be opened).
    private func handle(_ command: WatchCommand) async -> [String: Any] {
        guard let app else { return [:] }
        switch command {
        case .refresh:
            break
        case .answer(let answer, let allow):
            if let remote = RemoteStore.sessionId(of: answer.agentId) {
                _ = await app.remote.answer(session: remote, request: answer.eventId, allow: allow)
            } else if let approval = app.approvals[answer.agentId]?.first(where: { $0.id == answer.eventId }) {
                await app.answerApproval(approval, session: answer.agentId, allow: allow)
            }
        case .seen(let ids):
            completions.removeAll { ids.contains($0.id) }
        }
        var snapshot = Self.snapshot(of: app)
        snapshot.sessions = snapshot.sessions.map { session in
            var session = session
            session.since = runningSince[session.id]
            return session
        }
        snapshot.completions = completions
        sent = snapshot
        wanted = snapshot
        snapshot.writtenAt = .now
        return WatchWire.pack(snapshot)
    }

    private static func snapshot(of app: AppModel) -> WatchSnapshot {
        let board = SessionBoard(app)
        let rank: (WatchSnapshot.Phase) -> Int = { $0.waiting ? 0 : $0 == .running ? 1 : 2 }
        func phase(_ phase: SessionBoard.Phase?) -> WatchSnapshot.Phase {
            switch phase {
            case .approval: .approval
            case .question: .question
            case .running: .running
            case nil: .idle
            }
        }
        let away = SessionBoard.away(in: app).map { session in
            WatchSnapshot.Session(
                id: session.id,
                title: session.title,
                phase: phase(session.phase),
                detail: session.detail,
                approval: session.approval.map { .init(eventId: $0.eventId, agentId: $0.agentId) },
                since: nil,
                updatedAt: session.updatedAt
            )
        }
        let sessions = (SessionBoard.listed(in: app)
            .map { summary in
                let entry = board.entries[summary.id]
                let phase = phase(entry?.phase)
                return WatchSnapshot.Session(
                    id: summary.id,
                    title: app.title(of: summary.id),
                    phase: phase,
                    detail: entry?.detail,
                    approval: entry?.approval.map { .init(eventId: $0.eventId, agentId: $0.agentId) },
                    since: nil,
                    updatedAt: summary.updatedAt
                )
            } + away)
            .sorted { lhs, rhs in
                let l = rank(lhs.phase), r = rank(rhs.phase)
                return l != r ? l < r : lhs.updatedAt > rhs.updatedAt
            }
            .prefix(limit)

        let balance = app.account.wallets.flatMap { wallets in
            wallets.isEmpty ? nil : wallets.map { formatBalance($0["balance"].string ?? "0", currency: $0["currency"].string) }.joined(separator: " + ")
        }
        // Read so that opening a session on the phone re-derives (its completion is then dropped).
        _ = app.currentSession
        return WatchSnapshot(writtenAt: .distantPast, sessions: Array(sessions), balance: balance, completions: [])
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.sent = nil
            self.refresh()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The watch app was installed after this app started: what could not be delivered then goes out now.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.sent = nil
            self.refresh()
        }
    }

    /// A different watch was paired: activate for it.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// A command sent while the phone was out of reach.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let command = WatchWire.command(in: userInfo) else { return }
        Task { @MainActor in
            _ = await self.handle(command)
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = WatchWire.command(in: message) else { return replyHandler([:]) }
        Task { @MainActor in
            let reply = await self.handle(command)
            replyHandler(reply)
        }
    }
}
