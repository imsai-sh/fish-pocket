import Foundation
import Observation
import WidgetKit

/// Keeps the widgets' snapshot (`WidgetSnapshot`) in step with the app: rewritten
/// shortly after what it shows changes, and confirmed every few minutes while work
/// runs so that the widgets can tell a running session from a stale one.
/// Reloads are asked for only when something was written.
@MainActor
final class WidgetSnapshotWriter {
    /// 设置 → 小组件显示会话标题. Off: no title or detail reaches the shared container.
    static let showTitlesKey = "dsh.widget.showTitles"
    /// MainView's current workspace.
    static let workspaceKey = "dsh.currentWorkspace"

    static let shared = WidgetSnapshotWriter()

    /// Sessions in the snapshot: the large widget shows six.
    private static let limit = 6
    private static let debounce = Duration.seconds(1)
    /// Well inside `WidgetSnapshot.staleAfter`.
    private static let heartbeat = Duration.seconds(10 * 60)

    private weak var app: AppModel?
    /// The content last written, `writtenAt` aside.
    private var written: WidgetSnapshot?
    private var wanted: WidgetSnapshot?
    /// When each session was first seen running in this run of the app.
    private var runningSince: [String: Date] = [:]
    private var pendingWrite: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    private init() {}

    func attach(_ app: AppModel) {
        self.app = app
        observe()
    }

    /// A setting or the current workspace changed: both live outside the model.
    func refresh() {
        guard let app else { return }
        apply(Self.snapshot(of: app))
    }

    private func observe() {
        guard let app else { return }
        let next = withObservationTracking { Self.snapshot(of: app) } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(next)
    }

    private func apply(_ snapshot: WidgetSnapshot) {
        var next = snapshot
        let now = Date.now
        let running = Set(next.sessions.filter { $0.phase == .running }.map(\.id))
        runningSince = runningSince.filter { running.contains($0.key) }
        for id in running where runningSince[id] == nil { runningSince[id] = now }
        next.sessions = next.sessions.map { session in
            var session = session
            session.since = runningSince[session.id]
            return session
        }
        wanted = next
        guard next != written else { return }
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    private func write() {
        guard var snapshot = wanted else { return }
        written = snapshot
        snapshot.writtenAt = .now
        WidgetSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        keepConfirming(!snapshot.active.isEmpty)
    }

    /// While sessions are active the snapshot is confirmed now and then; idle needs no confirming.
    private func keepConfirming(_ on: Bool) {
        guard on else {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            return
        }
        guard heartbeatTask == nil else { return }
        // `write` cancels it once nothing is active.
        heartbeatTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.heartbeat)
                guard !Task.isCancelled, let self else { return }
                self.write()
            }
        }
    }

    /// Top-level sessions only: a subagent's approval or question shows on the session it serves.
    /// With them, the sessions on a computer that the phone answers for.
    private static func snapshot(of app: AppModel) -> WidgetSnapshot {
        let showTitles = UserDefaults.standard.object(forKey: showTitlesKey) as? Bool ?? true
        let board = SessionBoard(app)
        func phase(_ id: String) -> WidgetSnapshot.Phase {
            switch board.entries[id]?.phase {
            case .approval: .approval
            case .question: .question
            case .running: .running
            case nil: .idle
            }
        }

        let rank: (WidgetSnapshot.Phase) -> Int = { $0.waiting ? 0 : $0 == .running ? 1 : 2 }
        let away = SessionBoard.away(in: app).map { session in
            let phase: WidgetSnapshot.Phase = switch session.phase {
            case .approval: .approval
            case .question: .question
            case .running: .running
            case nil: .idle
            }
            return WidgetSnapshot.Session(
                id: session.id,
                title: showTitles ? session.title : nil,
                phase: phase,
                detail: showTitles ? session.detail : nil,
                since: nil,
                updatedAt: session.updatedAt
            )
        }
        let sessions = (SessionBoard.listed(in: app)
            .map { summary in
                WidgetSnapshot.Session(
                    id: summary.id,
                    title: showTitles ? app.title(of: summary.id) : nil,
                    phase: phase(summary.id),
                    detail: showTitles ? board.entries[summary.id]?.detail : nil,
                    since: nil,
                    updatedAt: summary.updatedAt
                )
            } + away)
            .sorted { lhs, rhs in
                let l = rank(lhs.phase), r = rank(rhs.phase)
                return l != r ? l < r : lhs.updatedAt > rhs.updatedAt
            }
            .prefix(limit)

        let workspaceId = UserDefaults.standard.string(forKey: workspaceKey)
        let workspace = app.workspaces.first { $0.id == workspaceId } ?? app.workspaces.first
        return WidgetSnapshot(writtenAt: .distantPast, sessions: Array(sessions), workspace: workspace?.displayTitle)
    }
}
