import SwiftUI

/// What a file is called by, read off its name: no table of known formats to keep up.
enum FileFormat {
    /// The extension in capitals, empty when the name has none.
    static func ext(_ name: String) -> String {
        (name as NSString).pathExtension.uppercased()
    }

    /// 「XLSX · 20 KB」; a name without an extension reads 「文件」.
    static func caption(_ name: String, bytes: Int?) -> String {
        let ext = ext(name)
        let format = ext.isEmpty ? String(localized: "文件") : String(ext.prefix(12))
        guard let bytes else { return format }
        return format + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A sheet of paper with a folded corner, labelled with the file's own extension.
/// An extension too long for the label (or none) leaves the page with lines of text.
struct FileGlyph: View {
    let name: String
    var height: CGFloat = 40

    var body: some View {
        let ext = FileFormat.ext(name)
        let labelled = !ext.isEmpty && ext.count <= 4
        let overhang = height * 0.12
        let page = PageShape(fold: height * 0.28, radius: height * 0.12)
        ZStack(alignment: .bottomLeading) {
            ZStack {
                page.fill(Palette.background)
                page.stroke(Palette.stroke, lineWidth: max(1, height / 40))
                PageFold(fold: height * 0.28, radius: height * 0.06).fill(Palette.stroke)
                if !labelled {
                    VStack(alignment: .leading, spacing: height * 0.09) {
                        ForEach([0.46, 0.46, 0.3], id: \.self) { width in
                            Capsule().fill(Palette.stroke).frame(width: height * width, height: max(1.5, height * 0.05))
                        }
                    }
                    .offset(y: height * 0.12)
                }
            }
            .frame(width: height * 0.76, height: height)
            .padding(.leading, overhang)
            if labelled {
                Text(ext)
                    .font(.system(size: height * 0.21, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.onInk)
                    .padding(.horizontal, height * 0.08)
                    .padding(.vertical, height * 0.035)
                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: height * 0.09, style: .continuous))
                    .fixedSize()
                    .padding(.bottom, height * 0.15)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The page outline: a rounded rectangle whose top right corner is cut for the fold.
private struct PageShape: Shape {
    let fold: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}

/// The corner folded down over the page.
private struct PageFold: Shape {
    let fold: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addArc(tangent1End: CGPoint(x: rect.maxX - fold, y: rect.minY + fold), tangent2End: CGPoint(x: rect.maxX - fold, y: rect.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}

/// A file in a message: its glyph, its name and its format.
struct FileCard: View {
    let name: String
    var bytes: Int?

    var body: some View {
        HStack(spacing: 10) {
            FileGlyph(name: name)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                Text(FileFormat.caption(name, bytes: bytes)).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
