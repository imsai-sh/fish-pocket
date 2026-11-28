import Foundation

// Which dock a window's notices sit above (`app/DshIOS/Core/BottomDocks.swift`).
// Run with `scripts/test-swift-units.sh`.

enum LayoutLoopGuard { static func tick(_ name: StaticString) {} }

@main
enum BottomDocksTests {
    @MainActor
    static func main() {
        var failures = 0
        func expect(_ value: CGFloat?, _ wanted: CGFloat?, _ what: String) {
            if value == wanted { print("ok   \(what)") } else { failures += 1; print("FAIL \(what): \(value.map { "\($0)" } ?? "nil") ≠ \(wanted.map { "\($0)" } ?? "nil")") }
        }

        let docks = BottomDocks()
        let conversation = UUID(), pushed = UUID()
        expect(docks.top, nil, "no dock, no top")

        // A dock reports its place before it is on screen, then comes on screen.
        docks.move(conversation, to: 700)
        expect(docks.top, nil, "a dock not yet on screen does not count")
        docks.show(conversation)
        expect(docks.top, 700, "the conversation's dock")
        docks.move(conversation, to: 400)
        expect(docks.top, 400, "it follows the dock (the keyboard came up)")

        // A page pushed over it: its own dock counts, the one under it keeps its place.
        docks.show(pushed)
        docks.move(pushed, to: 690)
        docks.hide(conversation)
        expect(docks.top, 690, "the page in front")
        docks.move(conversation, to: -34)
        expect(docks.top, 690, "the page under it moving does not move the notices")

        // Back to the conversation: its last place, without reporting again.
        docks.hide(pushed)
        docks.show(conversation)
        expect(docks.top, -34, "back to the page under it: its last place")
        docks.hide(conversation)
        expect(docks.top, nil, "no dock on screen, no top")

        // Many pages come and go: only the ones on screen are sure to be kept.
        let kept = UUID()
        docks.show(kept)
        docks.move(kept, to: 650)
        for _ in 0..<40 { let gone = UUID(); docks.move(gone, to: 1) }
        expect(docks.top, 650, "the dock on screen survives the clean-up")

        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
