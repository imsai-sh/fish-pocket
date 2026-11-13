import UIKit
import UIKit.UIGestureRecognizerSubclass
import WebKit

/// What the agent is doing in a conversation's browser, for the workbench to draw over the page
/// (`BrowserAgentOverlay`): what it is doing, where it points, and when it presses.
///
/// It shows from the agent's first operation until the agent stops: its turn ends, it leaves the
/// browser alone for a while, or the user touches the page. A touch is the user taking over, so
/// everything goes at once; the agent's next operation brings it back.
@MainActor
@Observable
final class BrowserPresence {
    enum Action: String {
        case open, read, click, type, select, scroll, back, forward, reload, evaluate, screenshot
    }

    struct Pointer: Equatable {
        /// Where, as a fraction of the part of the page on screen; the overlay places it.
        var at: CGPoint
        /// Each press adds one, to set off the press once.
        var presses = 0
        /// Each swipe adds one, likewise; `down` is which way the page is scrolled.
        var swipes = 0
        var down = true
    }

    /// The session whose agent is at the page, while it is shown.
    private(set) var driver: String?
    /// The operation running now; nil between two.
    private(set) var action: Action?
    private(set) var pointer: Pointer?

    @ObservationIgnored private var idle: Task<Void, Never>?

    /// The agent leaves the page for this long between operations only to think; longer, it has
    /// moved on to something else.
    private static let linger: Duration = .seconds(30)

    func began(_ op: String, driver: String) {
        idle?.cancel()
        self.driver = driver
        action = Action(rawValue: op)
        // A new page: where the pointer was means nothing on it.
        if [.open, .back, .forward, .reload].contains(action) { pointer = nil }
    }

    func ended() {
        guard driver != nil else { return }
        action = nil
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// The user's hand on the page or the bar, or the agent gone: nothing is left on screen.
    func dismiss() {
        idle?.cancel()
        driver = nil
        action = nil
        pointer = nil
    }

    // MARK: From the page

    /// The page says where the pointer is only while an operation runs. Anything else (a page
    /// sending look-alike events, an operation the user cut off) draws nothing.
    private var accepting: Bool { driver != nil && action != nil }

    func move(to at: CGPoint) {
        guard accepting else { return }
        if pointer == nil { pointer = Pointer(at: at) } else { pointer?.at = at }
    }

    func press() {
        guard accepting else { return }
        pointer?.presses += 1
    }

    func swipe(at: CGPoint, down: Bool) {
        guard accepting else { return }
        move(to: at)
        pointer?.down = down
        pointer?.swipes += 1
    }

    /// One message from `entry.js`.
    fileprivate func receive(_ body: Any) {
        guard let body = body as? [String: Any], let kind = body["kind"] as? String else { return }
        if kind == "press" { press(); return }
        guard let x = (body["x"] as? NSNumber)?.doubleValue, let y = (body["y"] as? NSNumber)?.doubleValue,
              x.isFinite, y.isFinite else { return }
        // Off screen: the pointer stays where it was rather than leave the page.
        let at = CGPoint(x: x, y: y)
        guard (-0.02...1.02).contains(at.x), (-0.02...1.02).contains(at.y) else { return }
        switch kind {
        case "move": move(to: at)
        case "swipe": swipe(at: at, down: body["down"] as? Bool ?? true)
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

    /// Any finger on the page is the user taking over. It watches without taking part: it never
    /// recognises, so the page's own scrolling, taps and text selection go on as before. What the
    /// agent does reaches the page as DOM events and never comes through here.
    final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let touched: () -> Void

        init(_ touched: @escaping () -> Void) {
            self.touched = touched
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            touched()
            state = .failed
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
