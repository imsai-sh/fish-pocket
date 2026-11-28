import Foundation
import Observation

/// Where the bottom docks of a window's pages start (a conversation's composer, Mini Apps'
/// request bar), for the notices that sit just above them (`ShellNotices`). Below them, as a
/// fallback, the edge a tab's pages end at, over the tab bar: a page without a dock keeps the
/// notices above the bar rather than on it. One per window,
/// handed down from its root: a page in another window, or one pushed under the page in front,
/// never moves this window's notices.
///
/// Only the docks write here, and only their own place; nothing they lay out reads it, so no
/// value written here can come back to move the dock that wrote it.
@MainActor
@Observable
final class BottomDocks {
    private var tops: [UUID: CGFloat] = [:]
    /// The docks on screen, the one that came last at the end.
    private var shown: [UUID] = []
    /// Of those, the fallback edges: any dock goes before them, whichever came on screen first.
    private var edges: Set<UUID> = []

    /// The top of the dock that came on screen last, else of the fallback edge that did, in window
    /// coordinates; nil when there is neither.
    var top: CGFloat? {
        let dock = shown.last { !edges.contains($0) } ?? shown.last
        return dock.flatMap { tops[$0] }
    }

    func show(_ id: UUID, edge: Bool = false) {
        shown.removeAll { $0 == id }
        shown.append(id)
        if edge { edges.insert(id) }
    }

    func move(_ id: UUID, to top: CGFloat) {
        LayoutLoopGuard.tick("BottomDocks.move")
        guard tops[id] != top else { return }
        tops[id] = top
        // Docks off screen keep their place for when they come back (a page popped back to does
        // not report again); past a few, those of pages long gone are let go.
        if tops.count > 16 { tops = tops.filter { shown.contains($0.key) || $0.key == id } }
    }

    func hide(_ id: UUID) {
        shown.removeAll { $0 == id }
        edges.remove(id)
    }
}
