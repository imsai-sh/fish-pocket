import QuickLook
import SwiftUI

/// A file of a remote session: on its computer, or carried by one of its messages.
enum RemoteFile: Hashable {
    /// On the computer at `path`, which may be relative to `root` (the session's folder).
    case device(deviceId: String, root: String?, path: String)
    /// Attached to a message; `cwd` is where a computer-side attachment's relative path starts.
    case attachment(RemoteAttachment, deviceId: String?, cwd: String?)

    var name: String {
        switch self {
        case .device(_, _, let path): RemoteFileLinks.displayName(path)
        case .attachment(let attachment, _, _): attachment.name
        }
    }

    /// Where it is on the computer, when it is there.
    var path: String? {
        switch self {
        case .device(_, _, let path):
            return path
        case .attachment(let attachment, _, _):
            if case .device(_, let path) = attachment.source { return path }
            return nil
        }
    }

    fileprivate var deviceId: String? {
        switch self {
        case .device(let id, _, _): id
        case .attachment(_, let id, _): id
        }
    }

    /// Offline computers are said so before anything is asked of them.
    @MainActor fileprivate var online: Bool {
        guard let deviceId else { return true }
        return RemoteStore.shared.device(deviceId)?.online ?? true
    }

    @MainActor fileprivate var client: RemoteClient {
        get throws {
            guard let client = RemoteStore.shared.client else { throw RemoteError(kind: .unauthorized, message: String(localized: "尚未登录")) }
            return client
        }
    }

    /// The whole file.
    @MainActor func data() async throws -> Data {
        switch self {
        case .device(let deviceId, let root, let path):
            try await RemoteFileFetch.device(path: path, root: root, client: client, deviceId: deviceId, online: online)
        case .attachment(let attachment, let deviceId, let cwd):
            try await RemoteFileFetch.data(attachment, client: client, deviceId: deviceId, cwd: cwd, online: online)
        }
    }

    /// The file as text, at most its first megabyte; nil when it is not text.
    @MainActor func text() async throws -> (text: String, truncated: Bool, size: Int?)? {
        let limit = 1_048_576
        guard case .device(let deviceId, let root, let path) = self else {
            let data = try await data()
            let head = data.prefix(limit)
            var text = String(data: head, encoding: .utf8)
            // Cut at the limit, the last character may be split.
            if text == nil, data.count > limit {
                text = (1...3).lazy.compactMap { String(data: head.dropLast($0), encoding: .utf8) }.first
            }
            guard let text, !text.contains("\0") else { return nil }
            return (text, data.count > limit, data.count)
        }
        guard online else { throw RemoteError(kind: .offline, message: String(localized: "电脑离线，暂时打不开电脑上的文件")) }
        let folder = root.flatMap { $0.isEmpty ? nil : $0 } ?? "."
        let value = try await client.post("/connectors/\(RemoteClient.encode(deviceId))/fs/readText",
                                          ["path": .string(path), "maxBytes": .number(Double(limit))], query: ["root": folder])
        guard value["ok"].bool != false else {
            throw RemoteError(kind: .rejected, message: value["error"]["message"].string ?? String(localized: "电脑没有返回这个文件"))
        }
        if value["binary"].bool == true { return nil }
        return (value["content"].string ?? "", value["truncated"].bool ?? false, value["size"].int)
    }

    /// Where links in a Markdown file start: the folder it is in, on the same computer.
    var linkScope: FileLinkScope? {
        guard case .device(let deviceId, let root, let path) = self else { return nil }
        return FileLinkScope(sessionId: "", root: RemoteFileLinks.folder(of: path, root: root), deviceId: deviceId)
    }
}

/// A remote file shown in place, as a local one is (`FileContentView`): Markdown laid out,
/// text with line numbers (a `#L24` link marks and scrolls to its lines), pictures, PDFs, and
/// Word, Excel, PowerPoint and the rest in the system's Quick Look viewer inside the page.
/// Text is read off the computer (its first megabyte); anything else is downloaded once into a
/// temporary copy, which goes when the page does.
struct RemoteFileView: View {
    let file: RemoteFile
    var lines: ClosedRange<Int>? = nil
    /// The size, when the list it was opened from knows it.
    var size: Int? = nil

    @State private var chosen: FileRenderer?
    @State private var text: [String]?
    @State private var truncated = false
    @State private var knownSize: Int?
    @State private var localURL: URL?
    @State private var failure: String?
    @State private var wrap = true
    @State private var preview: URL?
    @State private var fetching = false
    /// Bumped by 重新读取.
    @State private var revision = 0
    /// The copies on the phone, gone with the page (not when Quick Look covers it).
    @State private var copies = TemporaryCopies()
    @Environment(AppModel.self) private var app

    private var name: String { file.name }
    private var renderers: [FileRenderer] {
        var list = FileRenderer.candidates(for: name)
        // An attachment named without an extension still says what it is.
        if (name as NSString).pathExtension.isEmpty, case .attachment(let attachment, _, _) = file {
            if attachment.isImage { list = [.image] } else if attachment.mediaType == "application/pdf" { list = [.pdf] }
        }
        // Read as text and found not to be: the system's viewer, which knows more formats.
        if chosen == .unsupported, !list.contains(.unsupported) { list.append(.unsupported) }
        return list
    }
    /// A `#L` link needs line anchors, which rendered Markdown does not have.
    private var renderer: FileRenderer { chosen ?? (lines != nil && renderers.contains(.text) ? .text : renderers[0]) }

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView {
                    Label("无法打开文件", systemImage: "doc.questionmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("重试") { reload() }
                }
            } else if renderer.pagesText ? text == nil : localURL == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(renderer.pagesText ? "正在从电脑读取…" : "正在下载…").font(.footnote).foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch renderer {
                case .text: plainText
                case .markdown: markdown
                case .image: if let localURL { ZoomableImage(url: localURL).id(revision) }
                case .webImage: if let localURL { InlineImageWebView(url: localURL).id(revision) }
                case .pdf: if let localURL { PDFPreview(url: localURL).id(revision) }
                case .unsupported:
                    if let localURL, QLPreviewController.canPreview(localURL as NSURL) {
                        QuickLookView(url: localURL).id(revision).ignoresSafeArea(edges: .bottom)
                    } else {
                        unsupported
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { actions }
        }
        .quickLookPreview($preview)
        .task(id: LoadKey(renderer: renderer, revision: revision)) { await load() }
    }

    private struct LoadKey: Hashable { let renderer: FileRenderer; let revision: Int }

    private var actions: some View {
        Menu {
            if renderers.count > 1 {
                Picker("打开方式", selection: Binding(get: { renderer }, set: { chosen = $0; Haptics.select() })) {
                    ForEach(renderers, id: \.self) { Text($0.label).tag($0) }
                }
            }
            if renderer == .text {
                Toggle("自动换行", isOn: $wrap)
            }
            Button { reload() } label: { Label("重新读取文件", systemImage: "arrow.clockwise") }
            if renderer.pagesText, let text {
                Button { copyToPasteboard(text.joined(separator: "\n")) } label: { Label("复制内容", systemImage: "doc.on.clipboard") }
            }
            if let path = file.path {
                Button { copyToPasteboard(path) } label: { Label("复制路径", systemImage: "doc.on.doc") }
            }
            Button { withCopy { preview = $0 } } label: { Label("快速查看", systemImage: "eye") }
            Button { withCopy { presentShareSheet([$0]) } } label: { Label("分享", systemImage: "square.and.arrow.up") }
        } label: {
            if fetching { ProgressView().controlSize(.small) } else { Image(systemName: "ellipsis") }
        }
        .disabled(fetching)
        .accessibilityLabel("文件操作")
    }

    /// A format with no renderer here, Quick Look's included: the file, and the way to take it elsewhere.
    private var unsupported: some View {
        VStack(spacing: 20) {
            FileGlyph(name: name, height: 96)
            VStack(spacing: 6) {
                Text(name).font(.headline).foregroundStyle(Palette.ink).multilineTextAlignment(.center).lineLimit(3)
                Text(FileFormat.caption(name, bytes: knownSize ?? size)).font(.subheadline).foregroundStyle(Palette.secondary)
            }
            if let localURL {
                Button { presentShareSheet([localURL]) } label: { Label("分享", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.capsule(.secondary, height: 44, fill: false))
                    .padding(.top, 4)
            }
        }
        .padding(32)
    }

    // MARK: Text

    private var plainText: some View {
        let text = text ?? []
        return ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let digits = String(text.count).count
                    ForEach(text.indices, id: \.self) { index in
                        row(index + 1, text[index], digits: digits)
                    }
                    if truncated { cut.padding(.horizontal).padding(.top, 8) }
                }
                .padding(.vertical)
            }
            .defaultScrollAnchor(.topLeading)
            .refreshable { reload() }
            .onAppear { if let lines { proxy.scrollTo(lines.lowerBound, anchor: .center) } }
        }
    }

    private func row(_ number: Int, _ line: String, digits: Int) -> some View {
        let marked = lines?.contains(number) ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(number))
                .foregroundStyle(marked ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(.tertiary))
                .fixedSize()
                .frame(minWidth: CGFloat(digits) * 9, alignment: .trailing)
            Group {
                if wrap {
                    Text(line.isEmpty ? " " : line).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(line.isEmpty ? " " : line).fixedSize()
                }
            }
            .textSelection(.enabled)
        }
        .font(.system(.footnote, design: .monospaced))
        .padding(.horizontal)
        .padding(.vertical, 1)
        .background(marked ? Palette.ink.opacity(0.12) : .clear)
        .id(number)
    }

    private var cut: some View {
        Text("文件较大，只显示开头的 1 MB。").font(.footnote).foregroundStyle(Palette.secondary)
    }

    // MARK: Markdown

    private var markdown: some View {
        let document = MarkdownDocument((text ?? []).joined(separator: "\n"))
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !document.fields.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(document.fields, id: \.key) { field in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(field.key).foregroundStyle(Palette.secondary)
                                Text(field.value).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.footnote)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if let raw = document.rawFrontmatter {
                    Text(raw).font(.footnote.monospaced()).foregroundStyle(Palette.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                // Links and pictures in it are files beside it on the same computer.
                MarkdownView(text: document.body)
                    .modifier(LinkOpening())
                    .environment(\.fileLinkScope, file.linkScope)
                if truncated { cut }
            }
            .padding(20)
            .readableWidth()
        }
        .refreshable { reload() }
    }

    // MARK: Loading

    private func reload() {
        text = nil
        truncated = false
        discard()
        failure = nil
        revision += 1
    }

    private func load() async {
        failure = nil
        do {
            if renderer.pagesText {
                guard text == nil else { return }
                guard let read = try await file.text() else {
                    // Not text after all: the system's viewer gets the file.
                    chosen = .unsupported
                    return
                }
                knownSize = read.size
                truncated = read.truncated
                text = read.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            } else {
                guard localURL == nil else { return }
                localURL = try await copy()
            }
        } catch {
            let error = RemoteError(error)
            if error.kind != .cancelled { failure = error.message }
        }
    }

    /// The file on the phone, for Quick Look, sharing and the renderers that read from disk.
    private func copy() async throws -> URL {
        let data = try await file.data()
        knownSize = data.count
        let mediaType: String? = if case .attachment(let attachment, _, _) = file { attachment.mediaType } else { nil }
        let url = try RemoteFileFetch.temporaryCopy(data, name: name, mediaType: mediaType)
        copies.urls.append(url)
        return url
    }

    /// Runs `action` on the copy on the phone, downloading it first if the page shows text.
    private func withCopy(_ action: @escaping (URL) -> Void) {
        if let localURL { action(localURL); return }
        Haptics.tap()
        fetching = true
        Task {
            defer { fetching = false }
            do {
                let url = try await copy()
                localURL = url
                action(url)
            } catch {
                let error = RemoteError(error)
                if error.kind != .cancelled { app.showToast(error.message, tone: .warning) }
            }
        }
    }

    private func discard() {
        guard let localURL else { return }
        copies.remove(localURL)
        self.localURL = nil
    }
}

/// Temporary copies of remote files, removed when the page that made them goes.
private final class TemporaryCopies {
    var urls: [URL] = []

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        urls.removeAll { $0 == url }
    }

    deinit {
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

/// A remote file in a sheet of its own, from a card in the conversation.
struct RemoteFilePreviewSheet: View {
    let file: RemoteFile
    var size: Int? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RemoteFileView(file: file, size: size)
                .closeButton(dismiss)
        }
        .inkTint()
    }
}
