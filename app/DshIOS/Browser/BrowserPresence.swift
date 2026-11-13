import UIKit
import WebKit

/// Whether the agent is at work in a conversation's browser, for the page to show page-agent's
/// own effects (its glowing mask, pointer and panel; `entry.js`) and to take them down.
///
/// They show from the agent's first operation until the agent stops: its turn ends, it leaves the
/// browser alone for a while, or the user touches the page. A touch is the user taking over, so
/// everything goes at once; the agent's next operation brings it back.
@MainActor
@Observable
final class BrowserPresence {
    enum Action: String {
        case open, read, click, type, select, scroll, back, forward, reload, evaluate, screenshot
    }

    /// The session whose agent is at the page, while it is shown.
    private(set) var driver: String?
    /// The operation running now; nil between two.
    private(set) var action: Action?
    /// The user's hand ended it, rather than the agent finishing.
    private(set) var takenOver = false

    /// The panel's stop button: ends the agent's turn.
    @ObservationIgnored var stop: (() -> Void)?
    @ObservationIgnored private var idle: Task<Void, Never>?

    /// The agent leaves the page for this long between operations only to think; longer, it has
    /// moved on to something else.
    private static let linger: Duration = .seconds(30)

    func began(_ op: String, driver: String) {
        idle?.cancel()
        self.driver = driver
        takenOver = false
        action = Action(rawValue: op)
    }

    func ended() {
        guard driver != nil else { return }
        action = nil
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// The agent is done with the page.
    func finish() {
        idle?.cancel()
        driver = nil
        action = nil
    }

    /// The user's hand on the page or the bar: nothing is left on screen.
    func dismiss() {
        guard driver != nil else { return }
        takenOver = true
        finish()
    }

    /// One message from `entry.js`.
    fileprivate func receive(_ body: Any) {
        guard let body = body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "takeover": dismiss()
        case "stop":
            guard driver != nil else { return }
            stop?()
            dismiss()
        default: break
        }
    }
}

extension BrowserPresence {
    /// Hears `entry.js` in the agent's content world. It holds the presence weakly: the content
    /// controller keeps its handlers for as long as the web view lives.
    final class Listener: NSObject, WKScriptMessageHandler {
        static let name = "dshPointer"
        private weak var presence: BrowserPresence?

        init(_ presence: BrowserPresence) { self.presence = presence }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            let body = message.body
            MainActor.assumeIsolated { presence?.receive(body) }
        }
    }
}
