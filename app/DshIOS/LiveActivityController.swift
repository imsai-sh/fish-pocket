import ActivityKit
import Foundation
import Observation
import SwiftUI

/// Mirrors agent work onto one Live Activity while the user is away from it: the phone's own
/// sessions, and the ones on a computer that the phone answers for (`RemoteStore.attention`).
/// A turn that starts and ends in front of them shows nothing: the activity is
/// started as the app leaves the screen (the last moment iOS allows it), or
/// once work has gone on for a while, then updated as sessions run, wait for
/// approval or ask a question, and ended a little after all is idle. 已完成
/// stays on the lock screen only if they were away, until they come back.
/// Updates are local; the engine keeps running off screen (BackgroundKeeper),
/// so no push service is involved.
@MainActor
final class LiveActivityController {
    typealias State = DshActivityAttributes.ContentState

    /// Work that runs longer than this gets an activity even if the app stays on screen.
    private static let startDelay = Duration.seconds(10)

    static let shared = LiveActivityController()

    private weak var app: AppModel?
    private var activity: Activity<DshActivityAttributes>?
    private var last: State?
    private var cleaned = false
    /// The session list briefly reads idle between a prompt and its turn; end only after a quiet spell.
    private var pendingFinish: Task<Void, Never>?
    /// What the activity should show now; nil when all is idle.
    private var wanted: State?
    private var pendingStart: Task<Void, Never>?
    /// When the work behind `pendingStart` began, so the timer counts from there.
    private var runStartedAt: Date?
    /// 已完成 still on the lock screen; a return to the app clears it.
    private var finished: Activity<DshActivityAttributes>?
    private var onScreen = true

    private init() {}

    func attach(_ app: AppModel) {
        self.app = app
        DshActivityBridge.handler = { [weak app] eventId, agentId, allow in
            guard let app else { return }
            if let remote = RemoteStore.sessionId(of: agentId) {
                _ = await app.remote.answer(session: remote, request: eventId, allow: allow)
                return
            }
            guard let approval = app.approvals[agentId]?.first(where: { $0.id == eventId }) else { return }
            await app.answerApproval(approval, session: agentId, allow: allow)
        }
        if !cleaned {
            // Left over from a previous launch: nothing updates them any more.
            cleaned = true
            for stale in Activity<DshActivityAttributes>.activities {
                Task { await stale.end(nil, dismissalPolicy: .immediate) }
            }
        }
        observe()
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        onScreen = phase == .active
        if onScreen {
            dismissFinished()
            apply(wanted)
        } else if wanted != nil, activity?.activityState != .active {
            start()
        }
    }

    /// Re-derive on every change of what the state reads (sessions, approvals, projections).
    private func observe() {
        guard let app else { return }
        let next = withObservationTracking { Self.state(of: app) } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(next)
    }

    private func apply(_ next: State?) {
        wanted = next
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[live-activity] disabled in Settings")
            return
        }
        guard var next else {
            pendingStart?.cancel()
            pendingStart = nil
            runStartedAt = nil
            guard activity != nil, pendingFinish == nil else { return }
            let idleAt = Date.now
            pendingFinish = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.pendingFinish = nil
                self?.finish(at: idleAt)
            }
            return
        }
        pendingFinish?.cancel()
        pendingFinish = nil
        if let activity, activity.activityState == .active {
            next.startedAt = last?.startedAt ?? next.startedAt
            guard next != last else { return }
            // A new approval, the phone's own or one a computer sends without buttons to answer it here.
            let alert = next.phase == .approval && (last?.phase != .approval || last?.approval != next.approval || last?.sessionId != next.sessionId)
                ? AlertConfiguration(title: "等你允许", body: "\(next.title)：\(next.detail ?? "")", sound: .default)
                : nil
            last = next
            Task { await activity.update(ActivityContent(state: next, staleDate: nil), alertConfiguration: alert) }
        } else if onScreen {
            guard pendingStart == nil else { return }
            runStartedAt = .now
            pendingStart = Task { [weak self] in
                try? await Task.sleep(for: Self.startDelay)
                guard !Task.isCancelled else { return }
                self?.start()
            }
        } else {
            start()
        }
    }

    private func start() {
        pendingStart?.cancel()
        pendingStart = nil
        guard var state = wanted else { return }
        state.startedAt = runStartedAt ?? state.startedAt
        do {
            activity = try Activity.request(attributes: DshActivityAttributes(), content: ActivityContent(state: state, staleDate: nil))
            last = state
        } catch {
            // Off screen a new activity cannot start; the next change on screen tries again.
            NSLog("[live-activity] not started: %@", String(describing: error))
            activity = nil
            last = nil
        }
    }

    /// Seen on screen there is nothing to report; otherwise 已完成 for a few minutes
    /// on the lock screen, while the island lets go at once.
    private func finish(at endedAt: Date) {
        guard let activity, var state = last else { return }
        self.activity = nil
        last = nil
        state.phase = .done
        state.detail = nil
        state.approval = nil
        state.others = 0
        state.endedAt = endedAt
        let policy: ActivityUIDismissalPolicy = onScreen ? .immediate : .after(.now.addingTimeInterval(5 * 60))
        if !onScreen { finished = activity }
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy) }
    }

    private func dismissFinished() {
        guard let finished else { return }
        self.finished = nil
        Task { await finished.end(nil, dismissalPolicy: .immediate) }
    }

    /// The focus: the oldest approval, then an open question, then the latest running session;
    /// at each step the phone's own before a computer's.
    private static func state(of app: AppModel) -> State? {
        let running = app.sessions.values.filter { $0.running && !$0.isSubagent }.sorted { $0.updatedAt > $1.updatedAt }
        let approvals = app.approvals.filter { !$0.value.isEmpty }
        let questions = app.sessions.keys.filter { id in
            app.control[id]?["userQuestions"]?["active"].array.isEmpty == false
        }.sorted()
        let away = app.remote.attention
        // A request not read yet is taken for an approval: that is what a session waits with, nearly always.
        let awayApproval = away.first { $0.waiting && app.remote.requests[$0.id]?.isApproval != false }
        let awayQuestion = away.first { $0.waiting && app.remote.requests[$0.id]?.isApproval == false }
        let awayRunning = away.first { !$0.waiting }
        var busy = Set(running.map(\.id)).union(approvals.keys).union(questions).union(away.map { RemoteStore.selection($0.id) })

        var state: State
        if let (agentId, pending) = approvals.min(by: { $0.key < $1.key }), let approval = pending.first {
            let reason = approval.reason?.isEmpty == false ? approval.reason! : String(localized: "工具 \(approval.toolName) 请求越权执行")
            state = State(phase: .approval, sessionId: agentId, title: title(agentId, in: app), others: 0, detail: reason,
                          approval: .init(eventId: approval.id, agentId: agentId), startedAt: .now)
        } else if let session = awayApproval {
            state = remote(session, phase: .approval, in: app)
        } else if let id = questions.first {
            let question = app.control[id]?["userQuestions"]?["active"].array.first?["questions"].array.first?["question"].string
            state = State(phase: .question, sessionId: id, title: title(id, in: app), others: 0, detail: question, startedAt: .now)
        } else if let session = awayQuestion {
            state = remote(session, phase: .question, in: app)
        } else if let session = running.first {
            state = State(phase: .running, sessionId: session.id, title: title(session.id, in: app), others: 0, startedAt: .now)
        } else if let session = awayRunning {
            state = remote(session, phase: .running, in: app)
        } else {
            return nil
        }
        busy.remove(state.sessionId)
        state.others = busy.count
        return state
    }

    /// A session on a computer: what it asks while it waits, else whose it is (the agent and
    /// the machine). The buttons come with an approval one tap answers.
    private static func remote(_ session: RemoteSession, phase: State.Phase, in app: AppModel) -> State {
        let id = RemoteStore.selection(session.id)
        let request = session.waiting ? app.remote.requests[session.id] : nil
        let place = "\(session.agentTag) · \(app.remote.deviceName(of: session))"
        return State(phase: phase, sessionId: id, title: session.displayTitle, others: 0, detail: request?.summary ?? place,
                     approval: request?.quickAnswers == nil ? nil : request.map { .init(eventId: $0.id, agentId: id) }, startedAt: .now)
    }

    /// Approvals may come from a subagent, which has no title of its own.
    private static func title(_ id: String, in app: AppModel) -> String {
        if let session = app.sessions[id], !session.isSubagent { return app.title(of: id) }
        return String(localized: "子智能体")
    }
}
