import UIKit

/// A conversation's model as `SessionKeeper` keeps it between visits.
@MainActor
protocol KeptSession: AnyObject {
    var keptId: String { get }
    /// A page shows it (again): follow the session, catching up from what it holds.
    func resume()
    /// No page shows it any more, but it stays for the next visit: stop following.
    func park()
    /// The app left the front while a page shows it: stop following, keep what is on screen.
    func suspend()
    /// It is no longer kept.
    func close()
}

/// The conversations opened in this run of the app, the most recently shown last. A model stays
/// after its page closes, so opening the conversation again shows at once what it held and only
/// has to catch up. In memory only: nothing of a conversation is written to the phone for this.
/// Local conversations (DSH's own, a Bot's chat, a group) and remote ones each have one.
@MainActor
final class SessionKeeper<Model: KeptSession> {
    private var kept: [Model] = []
    /// How many pages show each conversation now (one can be open in more than one window).
    private var showing: [String: Int] = [:]
    private let limit: Int
    /// The owner says when the app is in front (`setInFront`); a local engine is followed either way.
    private(set) var inFront = true
    private var observer: NSObjectProtocol?

    init(limit: Int = 8) {
        self.limit = limit
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shed() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Every kept model, shown or not.
    var all: [Model] { kept }

    /// The conversation, for a page that shows it: the one kept from the last time it was open,
    /// which already holds its timeline, or a new one from `make` that reads it.
    func acquire(_ id: String, make: () -> Model) -> Model {
        let model = kept.first { $0.keptId == id } ?? make()
        kept.removeAll { $0 === model }
        kept.append(model)
        showing[id, default: 0] += 1
        if inFront { model.resume() }
        trim()
        return model
    }

    /// The page went away: following stops, what was read stays for the next time.
    func release(_ id: String) {
        guard let count = showing[id] else { return }
        showing[id] = count > 1 ? count - 1 : nil
        guard showing[id] == nil else { return }
        kept.first { $0.keptId == id }?.park()
        trim()
    }

    /// Conversations that are gone are not kept either.
    func forget(_ ids: Set<String>) {
        for model in kept where ids.contains(model.keptId) && showing[model.keptId] == nil { model.close() }
        kept.removeAll { ids.contains($0.keptId) && showing[$0.keptId] == nil }
    }

    /// Nothing is kept: the account or the engine went.
    func clear() {
        let models = kept
        kept = []
        showing = [:]
        models.forEach { $0.close() }
    }

    /// The app came to the front or left it: the conversations on screen follow or stop.
    func setInFront(_ front: Bool) {
        inFront = front
        for model in kept where showing[model.keptId] != nil { front ? model.resume() : model.suspend() }
    }

    /// Only the last few stay; a conversation on screen is never dropped.
    private func trim() {
        var extra = kept.count - limit
        for model in kept where extra > 0 && showing[model.keptId] == nil {
            model.close()
            kept.removeAll { $0 === model }
            extra -= 1
        }
    }

    /// The system is short of memory: every conversation not on screen is let go. Opened again,
    /// it reads as one opened for the first time does.
    private func shed() {
        for model in kept where showing[model.keptId] == nil { model.close() }
        kept.removeAll { showing[$0.keptId] == nil }
    }
}
