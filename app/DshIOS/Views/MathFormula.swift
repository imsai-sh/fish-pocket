import SwiftMath
import SwiftUI

/// On the placeholder character standing in for a formula: the formula it stands for.
enum MathFormulaKey: AttributedStringKey {
    typealias Value = MathSyntax.Formula
    static let name = "dsh.mathFormula"
}

/// A typeset formula: a picture of it, and how far it hangs below the text baseline.
struct TypesetMath {
    let image: UIImage
    let descent: CGFloat
}

/// Formulas drawn by SwiftMath, kept by source and size: a reply is laid out again
/// on every streamed token and every time its row scrolls back into view.
@MainActor
enum MathTypesetter {
    private final class Entry: NSObject {
        let math: TypesetMath?
        init(_ math: TypesetMath?) { self.math = math }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 600
        return cache
    }()

    /// Nil when the formula cannot be typeset; its source is shown instead.
    static func typeset(_ formula: MathSyntax.Formula, size: CGFloat) -> TypesetMath? {
        let key = "\(formula.display ? "D" : "T")\(size) \(formula.latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.math }
        let math = draw(formula, size: size)
        cache.setObject(Entry(math), forKey: key)
        return math
    }

    private static func draw(_ formula: MathSyntax.Formula, size: CGFloat) -> TypesetMath? {
        // On iOS SwiftMath draws nothing for characters its math font lacks, in `\text{}` too:
        // a formula with Chinese in it would lose them, so it is left as written.
        guard !formula.latex.contains(#/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\u{3000}-\u{303F}\u{FF00}-\u{FFEF}]/#) else { return nil }
        var latex = adapted(formula.latex)
        let boxed = unboxed(latex)
        if let boxed { latex = boxed }
        var picture = MathImage(latex: latex, fontSize: size, textColor: .black, labelMode: formula.display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = picture.asImage()
        guard error == nil, let image, let layout, image.size.width > 0 else { return nil }
        guard boxed != nil else { return TypesetMath(image: image, descent: layout.descent) }
        let inset = size * 0.4
        let frame = CGRect(origin: .zero, size: CGSize(width: image.size.width + inset * 2, height: image.size.height + inset * 2))
        let framed = UIGraphicsImageRenderer(size: frame.size).image { _ in
            image.draw(at: CGPoint(x: inset, y: inset))
            let border = UIBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
            UIColor.black.setStroke()
            border.stroke()
        }
        return TypesetMath(image: framed, descent: layout.descent + inset)
    }

    /// What models write that SwiftMath has under another name.
    private static func adapted(_ latex: String) -> String {
        latex
            .replacing(#/\\dots(?![A-Za-z])/#, with: #"\ldots"#)
            .replacing(#/\\(begin|end)\{align\*?\}/#) { "\\\($0.1){aligned}" }
    }

    /// The inside of a formula that is one `\boxed{…}`: SwiftMath has no box, so it is drawn around the picture.
    private static func unboxed(_ latex: String) -> String? {
        guard latex.hasPrefix("\\boxed{"), latex.hasSuffix("}") else { return nil }
        let inner = latex.dropFirst(7).dropLast()
        var depth = 0
        for character in inner {
            if character == "{" { depth += 1 } else if character == "}" { depth -= 1 }
            if depth < 0 { return nil }
        }
        return depth == 0 ? String(inner) : nil
    }
}

@MainActor
enum MathText {
    /// Inline Markdown with its formulas typeset in place, at the size of the text around them.
    static func text(_ string: AttributedString, size: CGFloat) -> Text {
        guard string.runs.contains(where: { $0[MathFormulaKey.self] != nil }) else { return Text(string) }
        var text = Text(verbatim: "")
        for run in string.runs {
            guard let formula = run[MathFormulaKey.self] else {
                text = text + Text(AttributedString(string[run.range]))
                continue
            }
            // Two equal formulas side by side share a run.
            for _ in string[run.range].characters {
                if let math = MathTypesetter.typeset(formula, size: size) {
                    text = text + Text(Image(uiImage: math.image).renderingMode(.template)).baselineOffset(-math.descent)
                } else {
                    text = text + Text(verbatim: formula.source).font(.system(size: size * 0.9, design: .monospaced))
                }
            }
        }
        return text
    }
}

/// A formula on lines of its own: centred, scrolling sideways when wider than the reply.
struct MathBlockView: View {
    let latex: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let size = UIFont.preferredFont(forTextStyle: .callout).pointSize
        if let math = MathTypesetter.typeset(.init(latex: latex, display: true, source: latex), size: size) {
            let image = Image(uiImage: math.image).renderingMode(.template).accessibilityLabel(Text(verbatim: latex))
            ViewThatFits(in: .horizontal) {
                image.frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) { image }
            }
            .padding(.vertical, 2)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: latex).font(.system(.footnote, design: .monospaced))
            }
        }
    }
}
