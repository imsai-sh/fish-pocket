import Foundation

/// File references in a remote agent's reply, read the way Agents Anywhere's own clients read
/// them (`web-next/src/lib/session-file-link.ts`): `file://` URIs, percent-encoded, `~`,
/// absolute, relative, Windows drive and UNC paths, with the `#L12`, `:12` and `:12:3` line
/// suffixes agents append. Paths stay as the computer writes them: its server resolves a
/// relative one against the session's folder.
enum RemoteFileLinks {
    /// A path on the computer and the lines it points at.
    struct Reference: Equatable {
        var path: String
        var lines: ClosedRange<Int>?
    }

    /// Extensions that make a bare name (`报告.pdf`) a file the agent means, not code (`console.log`).
    private static let documents: Set<String> = [
        "pdf", "doc", "docx", "docm", "dot", "dotx", "rtf", "odt", "pages",
        "ppt", "pptx", "pptm", "pps", "ppsx", "odp", "key",
        "xls", "xlsx", "xlsm", "ods", "numbers", "csv", "tsv",
        "html", "htm", "xhtml", "md", "markdown", "txt", "epub",
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "svg",
        "zip", "mp3", "mp4", "mov", "wav", "m4a",
    ]

    /// First words that make `open report.pdf` a command rather than a file name.
    private static let commands: Set<String> = [
        "bash", "cat", "cd", "code", "cp", "echo", "explorer", "git", "head", "less", "libreoffice",
        "ls", "more", "mv", "nano", "node", "npm", "npx", "open", "pandoc", "pnpm", "python",
        "python3", "rm", "sh", "soffice", "start", "tail", "touch", "type", "vi", "vim",
        "xdg-open", "yarn", "zsh",
    ]

    /// A link the reply's Markdown made, as Foundation parsed it; nil when it is not a file.
    static func reference(_ url: URL) -> Reference? {
        switch url.scheme?.lowercased() {
        case nil:
            return reference(destination: url.absoluteString)
        case "file":
            var path = url.path(percentEncoded: false)
            // `file://server/share/report.pdf` is a UNC path.
            if let host = url.host(percentEncoded: false), !host.isEmpty, host.lowercased() != "localhost" {
                path = "//" + host + path
            }
            let lines = LinkTarget.lines(url.fragment(percentEncoded: false))
            return clean(path, lines: lines)
        case let scheme? where scheme.count == 1 && scheme.first!.isLetter:
            // `C:\Users\…` or `C:/Users/…`: the drive letter reads as a scheme.
            return reference(destination: url.absoluteString)
        default:
            return nil
        }
    }

    /// A link destination as written: `docs/a.md#L12`, `C:\work\a.docx`, `~/out/b.pdf:3`.
    static func reference(destination: String) -> Reference? {
        var value = destination.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("<"), value.hasSuffix(">"), value.count >= 2 { value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
        guard !value.isEmpty, !value.hasPrefix("#"), !value.hasPrefix("//") else { return nil }
        if value.lowercased().hasPrefix("file:"), let url = URL(string: value) { return reference(url) }
        if value.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]+:.*/) != nil, value.firstMatch(of: /^[A-Za-z]:[\\\/]/) == nil { return nil }
        var lines: ClosedRange<Int>?
        if let anchor = value.firstMatch(of: /#(L\d+(?:C\d+)?(?:-L?\d+(?:C\d+)?)?)$/) {
            lines = LinkTarget.lines(String(anchor.1).replacing(/C\d+/, with: ""))
            value = String(value[..<anchor.range.lowerBound])
        }
        return clean(value.removingPercentEncoding ?? value, lines: lines)
    }

    /// An inline code span such as `` `docs/报告 终稿.pdf:3` ``, or nil when it is not a file.
    /// Stricter than a link: a bare name or a spaced path counts only with a document's
    /// extension and no shell syntax, so `ls -la out/report.pdf` stays code.
    static func reference(code: String) -> Reference? {
        let text = code.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("file:") { return reference(destination: text) }
        guard !text.contains("://"), !text.contains("\n") else { return nil }
        let (candidate, lines) = splitLineSuffix(text)
        let name = displayName(candidate)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let separated = candidate.contains("/") || candidate.contains("\\")
        let spaced = candidate.contains(where: \.isWhitespace)
        if spaced || !separated {
            guard documents.contains(ext) else { return nil }
            guard candidate.firstMatch(of: /[|&;<>`*?"]|\$\(|(?:^|\s)-{1,2}[A-Za-z]/) == nil else { return nil }
            let first = candidate.split(separator: " ").first.map(String.init) ?? ""
            if spaced, commands.contains(first.lowercased()) { return nil }
            if spaced, separated, candidate.firstMatch(of: /^(?:\/|~[\/\\]|\.{1,2}[\/\\]|[A-Za-z]:[\/\\]|\\\\)/) == nil,
               let segment = candidate.split(whereSeparator: { $0 == "/" || $0 == "\\" }).first, segment.contains(where: \.isWhitespace) {
                // `open out/a.pdf`: the first word reads like a command, not a folder.
                return nil
            }
        }
        return clean(candidate, lines: lines)
    }

    /// The last part of a path, whichever separator the computer uses.
    static func displayName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") || path.hasSuffix("\\") ? String(path.dropLast()) : path
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? trimmed
    }

    /// The folder `path` is in, as a root for the links in it: absolute when `path` is, else
    /// `root` and the folders `path` names.
    static func folder(of path: String, root: String?) -> String? {
        guard let cut = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return root }
        let parent = cut == path.startIndex ? String(path[...cut]) : String(path[..<cut])
        if isAbsolute(parent) { return parent }
        if parent.wholeMatch(of: /[A-Za-z]:/) != nil { return String(path[...cut]) }
        guard let root, !root.isEmpty else { return parent }
        let separator: Character = root.contains("\\") && !root.contains("/") ? "\\" : "/"
        return root.hasSuffix(String(separator)) ? root + parent : root + String(separator) + parent
    }

    /// `/…`, `~…`, `C:\…`, `\\server\…`.
    static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("\\\\") || path.firstMatch(of: /^[A-Za-z]:[\\\/]/) != nil
    }

    /// A link that opens `reference` through the conversation's `openURL`.
    static func url(_ reference: Reference) -> URL? {
        var components = URLComponents()
        components.scheme = "file"
        components.path = reference.path
        if let lines = reference.lines {
            components.fragment = lines.count > 1 ? "L\(lines.lowerBound)-L\(lines.upperBound)" : "L\(lines.lowerBound)"
        }
        return components.url
    }

    private static func clean(_ raw: String, lines: ClosedRange<Int>?) -> Reference? {
        let split = splitLineSuffix(raw.trimmingCharacters(in: .whitespaces))
        var value = split.0
        // The server marks a Windows drive root with a leading slash (`/C:/…`).
        if value.firstMatch(of: /^\/[A-Za-z]:(?:$|[\\\/])/) != nil { value.removeFirst() }
        value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return Reference(path: value, lines: lines ?? split.1)
    }

    /// `a.swift:12`, `a.swift:12-20`, `a.swift:12:3`: the path and its lines.
    private static func splitLineSuffix(_ value: String) -> (String, ClosedRange<Int>?) {
        guard let match = value.firstMatch(of: /:(\d+)(?:-(\d+))?(?::\d+)?$/),
              let start = Int(match.1), start > 0 else { return (value, nil) }
        let end = match.2.flatMap { Int($0) } ?? start
        let rest = String(value[..<match.range.lowerBound])
        // `C:` alone is a drive, not a file with a line.
        guard !rest.isEmpty, rest.wholeMatch(of: /[A-Za-z]/) == nil else { return (value, nil) }
        return (rest, start...max(start, end))
    }
}
