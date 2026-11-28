import Foundation

// How much of a tool's output is laid out (`app/DshIOS/Core/OutputCut.swift`).
// Run with `scripts/test-swift-units.sh`.

@main
enum OutputCutTests {
    static func main() {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            if ok { print("ok   \(what)") } else { failures += 1; print("FAIL \(what)") }
        }

        let short = OutputCut("a\nb\nc")
        expect(short.lines == 3 && !short.folds && !short.clipped && short.full == "a\nb\nc", "short output is shown as it is")

        let many = OutputCut((1...500).map(String.init).joined(separator: "\n"))
        expect(many.lines == 500 && many.folds, "many lines fold")
        expect(many.folded.hasPrefix("1\n2\n") && many.folded.hasSuffix("200\n…"), "folded to the first 200 lines")
        expect(!many.clipped, "open, all of it")

        // A minified file: one line of 3 MB.
        let started = Date()
        let line = String(repeating: "{\"k\":1},", count: 375_000)
        let single = OutputCut(line)
        let took = Date().timeIntervalSince(started)
        expect(single.lines == 1 && single.folds, "a single long line folds")
        expect(single.folded.count == OutputCut.foldedLimit + 2, "folded at the character limit")
        expect(single.clipped && single.full.count == OutputCut.fullLimit + 2, "open, cut at the open limit")
        expect(took < 1, "cut in under a second (\(String(format: "%.3f", took)) s)")

        // Characters, not bytes: Chinese text folds at the same number of characters.
        let chinese = OutputCut(String(repeating: "中", count: 8_000))
        expect(chinese.folds && chinese.folded.count == OutputCut.foldedLimit + 2, "characters counted, not bytes")
        let underLimit = OutputCut(String(repeating: "中", count: 3_000))
        expect(!underLimit.folds && underLimit.folded == underLimit.full, "under the limit in characters stays whole")

        let memo = OutputCut.Memo()
        let first = memo.of(line)
        expect(memo.of(line) == first && memo.of("x") == OutputCut("x"), "kept for the same text, worked out again for another")

        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
