import Foundation

/// How much of a tool's output is laid out: folded, the first lines and no more than a page's
/// worth of characters; open, a long but bounded stretch. Lines are counted without splitting
/// the text, so a long output costs one pass over its bytes.
struct OutputCut: Equatable {
    static let foldedLines = 200
    static let foldedLimit = 20_000
    static let fullLimit = 200_000

    let folded: String
    let full: String
    let lines: Int
    /// There is more than the folded part.
    let folds: Bool
    /// Even open, the end is left out.
    let clipped: Bool

    init(_ text: String) {
        var lines = 1
        var foldEnd: String.Index?
        var index = text.startIndex
        var characters = 0
        // Where the fold falls: after its last line, or at its character limit, whichever comes first.
        for scalar in text.unicodeScalars where scalar == "\n" { lines += 1 }
        if lines > Self.foldedLines || text.utf8.count > Self.foldedLimit {
            var seen = 1
            while index < text.endIndex, characters < Self.foldedLimit {
                if text[index] == "\n" {
                    if seen == Self.foldedLines { break }
                    seen += 1
                }
                index = text.index(after: index)
                characters += 1
            }
            if index < text.endIndex { foldEnd = index }
        }
        self.lines = lines
        folds = foldEnd != nil
        folded = foldEnd.map { String(text[..<$0]) + "\n…" } ?? text
        let fullEnd = text.index(text.startIndex, offsetBy: Self.fullLimit, limitedBy: text.endIndex) ?? text.endIndex
        clipped = fullEnd < text.endIndex
        full = clipped ? String(text[..<fullEnd]) + "\n…" : text
    }

    /// The last text's cut, kept by the view across redraws.
    final class Memo {
        private var source: String?
        private var cut: OutputCut?

        func of(_ text: String) -> OutputCut {
            if let cut, source == text { return cut }
            let next = OutputCut(text)
            source = text
            cut = next
            return next
        }
    }
}
