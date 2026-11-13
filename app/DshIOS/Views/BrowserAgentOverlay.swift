import SwiftUI

/// Keeps page-agent's effects on the page (`entry.js`: its glowing mask, pointer and panel) in step
/// with the agent: shown while it works, gone once its turn ends or the user takes over. It draws
/// nothing itself.
struct BrowserAgentOverlay: View {
    let model: BrowserPage
    @Environment(AppModel.self) private var app

    private var presence: BrowserPresence { model.presence }

    /// The agent's turn is still going. A session the list does not hold yet counts as going;
    /// the presence's own timeout ends that.
    private var running: Bool {
        guard let driver = presence.driver else { return false }
        return app.sessions[driver]?.running ?? true
    }

    private var state: BrowserPage.PageEffects {
        let shown = presence.driver != nil && (presence.action != nil || running)
        return .init(shown: shown, action: shown ? presence.action?.rawValue : nil, done: !presence.takenOver)
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: state, initial: true) { _, state in model.showEffects(state) }
            .onChange(of: running) { _, now in
                // The turn is over: nothing is left at the page.
                if !now, presence.action == nil { presence.finish() }
            }
    }
}
