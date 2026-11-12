import Foundation
import Observation
import WatchConnectivity
import WatchKit

/// The watch app's state: the last snapshot the phone sent, and the card for a
/// turn that just ended. Nothing is computed here that the phone does not know;
/// the wrist only draws, taps the user and sends back what they chose.
@MainActor
@Observable
final class WatchModel: NSObject {
    /// How the fish looks and what the first lines say.
    enum Mood { case offline, unknown, waiting, running, idle, done }

    /// A turn that ended, shown once: the newest, and how many others ended with it.
    struct Card: Identifiable, Equatable {
        let completion: WatchSnapshot.Completion
        let others: Int
        /// Which of `CompletionView.lines` the fish says.
        let line: Int
        var id: String { completion.id }
    }

    private(set) var snapshot: WatchSnapshot?
    /// The phone answered with nothing: its app is running without an engine (started in the background).
    private(set) var phoneAsleep = false
    var card: Card?

    @ObservationIgnored private var started = false
    /// Completions already on a card: the phone may list them once more before it hears they were seen.
    @ObservationIgnored private var shown: Set<String> = []

    var mood: Mood {
        guard let snapshot, !phoneAsleep else { return .offline }
        if snapshot.isStale(at: .now) { return .unknown }
        if !snapshot.waiting.isEmpty { return .waiting }
        return snapshot.running.isEmpty ? .idle : .running
    }

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if let demo = UserDefaults.standard.string(forKey: "dshWatchDemo") {
            if demo != "offline" { take(WatchSnapshot.demo(demo)) }
            return
        }
        #endif
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Ask the phone to do something. It answers with the snapshot as it stands afterwards.
    /// Out of reach, an answer still gets there later; a refresh is simply dropped.
    func send(_ command: WatchCommand) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        guard session.isReachable else {
            if command != .refresh { session.transferUserInfo(WatchWire.pack(command)) }
            return
        }
        session.sendMessage(WatchWire.pack(command)) { reply in
            let snapshot = WatchWire.snapshot(in: reply)
            Task { @MainActor in
                self.phoneAsleep = snapshot == nil
                if let snapshot { self.take(snapshot) }
            }
        } errorHandler: { _ in }
    }

    /// A tap on the fish: it answers on the wrist, and the phone is asked how things stand.
    func poke() {
        WKInterfaceDevice.current().play(.click)
        send(.refresh)
    }

    func answer(_ approval: WatchSnapshot.Approval, allow: Bool) {
        // The row leaves at once; the phone's answer confirms it.
        snapshot?.sessions.removeAll { $0.approval == approval }
        WKInterfaceDevice.current().play(.click)
        send(.answer(approval: approval, allow: allow))
    }

    private func take(_ next: WatchSnapshot) {
        let old = snapshot
        snapshot = next
        // A card for a session that is at work again has nothing left to say.
        if let card, next.sessions.contains(where: { $0.id == card.completion.sessionId && $0.phase.active }) { self.card = nil }
        let fresh = next.completions.filter { !shown.contains($0.id) }
        shown = Set(next.completions.map(\.id))
        if let latest = fresh.max(by: { $0.at < $1.at }) {
            // One tap on the wrist however many ended together.
            card = Card(completion: latest, others: fresh.count - 1, line: .random(in: 0..<CompletionView.lines.count))
            WKInterfaceDevice.current().play(.success)
            send(.seen(completions: fresh.map(\.id)))
        } else if let old, !Set(next.waiting.map(\.id)).isSubset(of: Set(old.waiting.map(\.id))) {
            WKInterfaceDevice.current().play(.notification)
        }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        var snapshot = WatchWire.snapshot(in: session.receivedApplicationContext)
        // What was kept from last time may list a turn already seen; the phone's answer says what is new.
        snapshot?.completions = []
        Task { @MainActor [snapshot] in
            if let snapshot { self.take(snapshot) }
            self.send(.refresh)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = WatchWire.snapshot(in: applicationContext) else { return }
        Task { @MainActor in
            self.phoneAsleep = false
            self.take(snapshot)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.send(.refresh) }
    }
}

#if DEBUG
extension WatchSnapshot {
    /// `-dshWatchDemo waiting|question|running|done|many|idle|unknown|offline`: a fixed snapshot, no phone needed.
    static func demo(_ name: String) -> WatchSnapshot {
        let now = Date.now
        func session(_ id: String, _ title: String, _ phase: Phase, detail: String? = nil, ago: TimeInterval) -> Session {
            Session(id: id, title: title, phase: phase, detail: detail,
                    approval: phase == .approval ? Approval(eventId: "e-\(id)", agentId: id) : nil,
                    since: phase == .running ? now.addingTimeInterval(-ago) : nil, updatedAt: now.addingTimeInterval(-ago))
        }
        let approval = session("a", "给贪吃蛇加排行榜", .approval, detail: "git push origin main", ago: 20)
        let running = session("b", "整理会议纪要", .running, ago: 95)
        let idle = [session("c", "初始化 Git 仓库", .idle, ago: 3600), session("d", "生成本月日历", .idle, ago: 86400)]
        switch name {
        case "waiting":
            return WatchSnapshot(writtenAt: now, sessions: [approval, running] + idle, balance: "¥23.80", completions: [])
        case "running":
            return WatchSnapshot(writtenAt: now, sessions: [running, session("e", "给贪吃蛇加排行榜", .running, ago: 12)] + idle, balance: "¥23.80", completions: [])
        case "done":
            return WatchSnapshot(writtenAt: now, sessions: [session("b", "整理会议纪要", .idle, ago: 5)] + idle, balance: "¥23.80",
                                 completions: [Completion(id: "k", sessionId: "b", title: "整理会议纪要", at: now)])
        case "question":
            return WatchSnapshot(writtenAt: now, sessions: [session("q", "部署新版本", .question, detail: "部署到测试环境还是生产环境？", ago: 40), running] + idle,
                                 balance: "¥23.80", completions: [])
        case "many":
            return WatchSnapshot(writtenAt: now, sessions: [session("b", "整理会议纪要", .idle, ago: 5)] + idle, balance: "¥23.80", completions: [
                Completion(id: "k1", sessionId: "c", title: "初始化 Git 仓库", at: now.addingTimeInterval(-3)),
                Completion(id: "k2", sessionId: "d", title: "生成本月日历", at: now.addingTimeInterval(-2)),
                Completion(id: "k3", sessionId: "b", title: "整理会议纪要", at: now),
            ])
        case "unknown":
            return WatchSnapshot(writtenAt: now.addingTimeInterval(-3 * 3600), sessions: [running] + idle, balance: nil, completions: [])
        default:
            return WatchSnapshot(writtenAt: now, sessions: idle, balance: "¥23.80", completions: [])
        }
    }
}
#endif
