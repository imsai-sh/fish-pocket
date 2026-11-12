import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The input of a remote conversation: the same bar as a local one (＋, the text, send or stop),
/// with what the agent on the computer offers behind ＋: pictures and files where it takes them,
/// its model and permission, and its slash commands as the draft starts with `/`.
struct RemoteComposer: View {
    @Bindable var model: RemoteSessionModel
    let openOptions: () -> Void
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photos: [PhotosPickerItem] = []
    /// Videos still coming out of the photo library: each shows as a reading chip until it
    /// joins the attachments (or is refused for its size).
    @State private var reading: [ReadingMovie] = []

    private struct ReadingMovie: Identifiable {
        let id = UUID()
        var progress: Progress?
        var fraction: Double?
    }

    private static let maxFiles = 10
    private static let maxBytes = 20 << 20

    private var empty: Bool {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty
    }

    var body: some View {
        let suggestions = focused ? model.suggestions(for: model.draft) : []
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty { commandPanel(suggestions) }
            VStack(alignment: .leading, spacing: 8) {
                if !model.attachments.isEmpty || !reading.isEmpty { rail }
                if let hint = commandHint {
                    Text(hint).font(.footnote).foregroundStyle(Palette.secondary).padding(.horizontal, 17).padding(.top, 4)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    plusMenu
                    TextField(model.busy && !model.canSend ? "智能体正在工作…" : "发消息", text: $model.draft, axis: .vertical)
                        .font(.callout)
                        .lineLimit(1...5)
                        .focused($focused)
                        .tint(Palette.ink)
                        .padding(.vertical, 11)
                    mainButton
                }
            }
            .padding(5)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        // The command list is read the first time a draft could name one.
        .task(id: model.draft.hasPrefix("/") && model.canCommand) {
            if model.draft.hasPrefix("/"), model.commands.isEmpty { await model.loadCommands() }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: max(1, Self.maxFiles - model.attachments.count - reading.count), matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { await add(photos: items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(files: urls) }
        }
    }

    // MARK: Parts

    private var plusMenu: some View {
        Menu {
            if model.canAttach {
                Button { showPhotos = true } label: { Label("照片", systemImage: "photo") }
                Button { showFiles = true } label: { Label("文件", systemImage: "doc") }
            }
            if model.canChoose {
                Button(action: openOptions) { Label("模型与权限", systemImage: "cpu") }
            }
            if model.canCommand {
                Button {
                    if model.draft.isEmpty { model.draft = "/" }
                    focused = true
                } label: { Label("指令", systemImage: "command") }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 19, weight: .regular)).foregroundStyle(Palette.ink).hitTarget()
        }
        .disabled(!model.canAttach && !model.canChoose && !model.canCommand)
        .accessibilityLabel("添加附件、调用指令、切换模型")
    }

    /// While the agent works, stop stays one tap away: alone with an empty draft, beside send once there is text.
    @ViewBuilder
    private var mainButton: some View {
        HStack(spacing: 0) {
            if model.busy {
                Button { Haptics.firm(); Task { await model.interrupt() } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 13)).foregroundStyle(empty ? Palette.onInk : Palette.ink)
                        .frame(width: 38, height: 38).background(empty ? Palette.ink : Palette.control, in: Circle())
                        .hitTarget()
                }
                .disabled(!model.canInterrupt)
                .keyboardShortcut(".", modifiers: .command)
                .accessibilityLabel("停止生成")
            }
            if !model.busy || !empty {
                let ready = !empty && model.canSend && reading.isEmpty
                Button { Haptics.tap(); Task { await model.send() } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ready ? Palette.onInk : Palette.faint)
                        .frame(width: 38, height: 38)
                        .background(ready ? Palette.ink : Palette.control, in: Circle())
                        .hitTarget()
                }
                .disabled(!ready)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("发送消息")
            }
        }
    }

    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, file in
                    HStack(spacing: 6) {
                        if file.mediaType.hasPrefix("image/"), let image = UIImage(data: file.data) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            Image(systemName: "doc").foregroundStyle(Palette.secondary)
                        }
                        Text(file.name).font(.caption).foregroundStyle(Palette.ink).lineLimit(1).frame(maxWidth: 120)
                        Button { model.attachments.remove(at: index) } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(Palette.secondary).hitTarget(30)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("移除 \(file.name)"))
                    }
                    .padding(.leading, 8)
                    .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                ForEach(reading) { movie in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(movie.fraction.map { String(localized: "正在读取 \(Int($0 * 100))%") } ?? String(localized: "正在从相册读取…"))
                            .font(.caption).foregroundStyle(Palette.secondary).lineLimit(1).monospacedDigit()
                        Button {
                            movie.progress?.cancel()
                            reading.removeAll { $0.id == movie.id }
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(Palette.secondary).hitTarget(30)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("移除 \(String(localized: "视频"))"))
                    }
                    .padding(.leading, 8)
                    .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 6)
    }

    /// The agent's commands the draft's `/…` could be.
    private func commandPanel(_ commands: [RemoteCommand]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands.prefix(30)) { command in
                    Button { pick(command) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "/\(command.id)").font(.subheadline.weight(.medium)).foregroundStyle(command.enabled ? Palette.ink : Palette.faint)
                            if let detail = command.detail, !detail.isEmpty {
                                Text(detail).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 220)
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// A command that takes arguments, typed with none yet: what to write after it.
    private var commandHint: String? {
        guard let slash = RemoteSlash(model.draft), !slash.rest.isEmpty,
              slash.rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return model.commands.first { $0.id == slash.command }?.hint
    }

    private func pick(_ command: RemoteCommand) {
        Haptics.select()
        if command.takesArguments {
            model.draft = "/\(command.id) "
        } else {
            model.draft = "/\(command.id)"
            Task { await model.send() }
        }
    }

    // MARK: Attachments

    private func add(photos items: [PhotosPickerItem]) async {
        for item in items {
            guard model.attachments.count + reading.count < Self.maxFiles else { break }
            if item.isMovie {
                // A video goes as a file, under the same size limit as one from Files; a chip shows while it is read.
                let movie = ReadingMovie()
                reading.append(movie)
                Task { await read(item, as: movie.id) }
                continue
            }
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { continue }
            // JPEG at a size any model takes: the original can be tens of megabytes of HEIC.
            let side = max(image.size.width, image.size.height)
            let scale = min(1, 2048 / max(side, 1))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { continue }
            model.attachments.append(RemoteUpload(name: "photo-\(model.attachments.count + 1).jpg", mediaType: "image/jpeg", data: jpeg))
        }
    }

    /// Read one picked video; its chip follows the library's progress and leaves when the file
    /// joins the attachments. A chip removed meanwhile cancels the read.
    private func read(_ item: PhotosPickerItem, as id: UUID) async {
        let watch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let index = reading.firstIndex(where: { $0.id == id }), let progress = reading[index].progress,
                      progress.totalUnitCount > 0 else { continue }
                reading[index].fraction = progress.fractionCompleted
            }
        }
        defer { watch.cancel() }
        do {
            let url = try await item.loadMovie { progress in
                if let index = reading.firstIndex(where: { $0.id == id }) { reading[index].progress = progress }
            }
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            guard reading.contains(where: { $0.id == id }) else { return }
            reading.removeAll { $0.id == id }
            add(files: [url])
        } catch {
            guard reading.contains(where: { $0.id == id }) else { return }
            reading.removeAll { $0.id == id }
            app.showToast(String(localized: "视频读取失败：\(error.localizedDescription)"))
        }
    }

    private func add(files urls: [URL]) {
        for url in urls {
            guard model.attachments.count < Self.maxFiles else {
                app.showToast(String(localized: "一次最多发送 \(Self.maxFiles) 个附件"))
                break
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
                app.showToast(String(localized: "不能发送文件夹，请添加单个文件"))
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard data.count <= Self.maxBytes else {
                app.showToast(String(localized: "「\(url.lastPathComponent)」超过 20 MB，没有添加"))
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            model.attachments.append(RemoteUpload(name: url.lastPathComponent, mediaType: type, data: data))
        }
    }
}
