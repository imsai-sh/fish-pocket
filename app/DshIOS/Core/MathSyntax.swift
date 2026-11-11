import Foundation

/// LaTeX in a reply. Formulas are cut out before the Markdown parser sees the text:
/// to it `\(` is an escaped bracket and `_`, `*` are emphasis, so it would rewrite them.
enum MathSyntax {
    struct Formula: Hashable, Sendable {
        var latex: String
        /// `$$ … $$` and `\[ … \]`, as opposed to `$ … $` and `\( … \)`.
        var display: Bool
        /// As written, delimiters included: what shows when the formula cannot be typeset.
        var source: String
    }

    /// Stands in for a formula while the text around it goes through Markdown.
    static let placeholder: Character = "\u{FFFC}"

    /// `text` with each formula replaced by `placeholder`, and the formulas in order.
    static func extract(_ text: String) -> (masked: String, formulas: [Formula]) {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else { return (text, []) }
        var masked = ""
        var formulas: [Formula] = []
        var rest = text.replacingOccurrences(of: String(placeholder), with: "\u{FFFD}")[...]

        func take(_ count: Int) {
            masked += rest.prefix(count)
            rest = rest.dropFirst(count)
        }
        func formula(open: String, close: String, display: Bool) -> Bool {
            let body = rest.dropFirst(open.count)
            guard let end = body.range(of: close) else { return false }
            return add(String(body[..<end.lowerBound]), display: display, upTo: end.upperBound)
        }
        func add(_ latex: String, display: Bool, upTo end: Substring.Index) -> Bool {
            let latex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return false }
            formulas.append(Formula(latex: latex, display: display, source: String(rest[..<end])))
            masked.append(placeholder)
            rest = rest[end...]
            return true
        }

        while let character = rest.first {
            if character == "`" {
                // A code span quotes its content: `$HOME` is not a formula.
                let ticks = rest.prefix(while: { $0 == "`" })
                let close = rest.dropFirst(ticks.count).range(of: ticks)
                take(close.map { rest.distance(from: rest.startIndex, to: $0.upperBound) } ?? ticks.count)
            } else if character == "\\" {
                if rest.hasPrefix("\\("), formula(open: "\\(", close: "\\)", display: false) { continue }
                if rest.hasPrefix("\\["), formula(open: "\\[", close: "\\]", display: true) { continue }
                take(2)
            } else if character == "$" {
                if rest.hasPrefix("$$"), formula(open: "$$", close: "$$", display: true) { continue }
                if let end = inlineDollarEnd(rest), add(String(rest[rest.index(after: rest.startIndex)..<end]), display: false, upTo: rest.index(after: end)) { continue }
                take(1)
            } else {
                take(1)
            }
        }
        return (masked, formulas)
    }

    /// The `$` closing a formula opened by the one `rest` starts with. A price is not a
    /// formula (`$5 和 $10`), nor a shell variable in prose, so as in pandoc: no space
    /// just inside either `$`, no digit right after the closing one, all on one line.
    private static func inlineDollarEnd(_ rest: Substring) -> Substring.Index? {
        var index = rest.index(after: rest.startIndex)
        guard index < rest.endIndex, !rest[index].isWhitespace, rest[index] != "$" else { return nil }
        while index < rest.endIndex {
            switch rest[index] {
            case "\n":
                return nil
            case "\\":
                index = rest.index(index, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex
            case "$":
                let after = rest.index(after: index)
                guard !rest[rest.index(before: index)].isWhitespace, after == rest.endIndex || !rest[after].isNumber else { return nil }
                return index
            default:
                index = rest.index(after: index)
            }
        }
        return nil
    }

    /// A formula on lines of its own, `first` being the trimmed line it opens on and
    /// `lines` what follows: `$$ … $$` or `\[ … \]`, closed before a blank line. The lines
    /// it spans are consumed. Unclosed (a reply still streaming) it stays text, as does one
    /// with text after it, which `extract` then finds inside the paragraph.
    static func displayBlock(_ first: String, _ lines: inout ArraySlice<String>) -> String? {
        guard let close = first.hasPrefix("$$") ? "$$" : first.hasPrefix("\\[") ? "\\]" : nil else { return nil }
        var body: [String] = []
        var line = String(first.dropFirst(2))
        var rest = lines
        while true {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(close) {
                body.append(String(trimmed.dropLast(close.count)))
                break
            }
            guard !trimmed.contains(close), let next = rest.first, !next.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            body.append(line)
            line = next
            rest = rest.dropFirst()
        }
        let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latex.isEmpty, !latex.contains(close) else { return nil }
        lines = rest
        return latex
    }
}
