import ActivityKit
import Foundation
import Observation
import UIKit

/// The sessions on a computer that the phone answers for, outside their conversations. The
/// lock screen and the widgets read them straight from `RemoteStore`; this keeps the rest in
/// step, as it is for the phone's own sessions: the app stays alive off screen while one of
/// them works, and a request in a session the user is not looking at is said once.
@MainActor
final class RemotePresence {
    static let shared = RemotePresence()

    private weak var app: AppModel?
    /// Requests already said.
    private var announced: Set<String> = []

    private init() {}

    func attach(_ app: AppModel) {
        self.app = app
        observe()
    }

    private func observe() {
        guard let app else { return }
        let (attention, requests) = withObservationTracking { (app.remote.attention, app.remote.requests) } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        app.remoteWorkChanged()
        announce(attention, requests: requests, in: app)
    }

    /// A request waits where the user is not looking: in the app a toast with the way there;
    /// away from it the Live Activity says so, or a notification where those are switched off
    /// (only when notifications are already allowed: this never asks).
    private func announce(_ attention: [RemoteSession], requests: [String: RemoteNotice], in app: AppModel) {
        announced.formIntersection(Set(requests.values.map(\.id)))
        for session in attention {
            guard let request = requests[session.id], !announced.contains(request.id) else { continue }
            announced.insert(request.id)
            let selection = RemoteStore.selection(session.id)
            let active = UIApplication.shared.applicationState == .active
            if active, app.currentSession == selection { continue }
            if !active, ActivityAuthorizationInfo().areActivitiesEnabled { continue }
            let text = request.isApproval ? String(localized: "「\(session.displayTitle)」等你允许") : String(localized: "「\(session.displayTitle)」等你回答")
            BotNotifier.announce(text, detail: request.summary, app: app) { [weak app] in app?.open(session: selection) }
        }
    }
}
