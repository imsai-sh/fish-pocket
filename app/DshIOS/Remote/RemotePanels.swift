import SwiftUI

/// The model, its reasoning level and the permission a remote session runs with: what the
/// agent on the computer offers, changed there.
struct RemoteOptionsSheet: View {
    let model: RemoteSessionModel
    @Environment(\.dismiss) private var dismiss

    private var modelSelection: String? { model.state?.selections["model"] ?? nil }
    private var permissionSelection: String? { model.state?.selections["permission"] ?? nil }

    var body: some View {
        NavigationStack {
            List {
                if let catalog = model.catalog {
                    let current = catalog.model(for: modelSelection)
                    if catalog.models.isEmpty, catalog.permissions.isEmpty {
                        Text("这个智能体没有可以在这里切换的选项。").foregroundStyle(Palette.secondary).groupedRow()
                    }
                    ForEach(groups(catalog.models), id: \.name) { group in
                        Section(group.name ?? String(localized: "模型")) {
                            ForEach(group.models) { option in
                                row(option.option, on: current?.model.id == option.id) {
                                    guard let selection = option.selection(effort: current?.model.id == option.id ? current?.effort?.id : nil) else { return }
                                    Task { await model.select("model", selection) }
                                }
                            }
                        }
                        .groupedRow()
                    }
                    if let current, !current.model.efforts.isEmpty {
                        Section("推理档位") {
                            ForEach(current.model.efforts) { effort in
                                row(effort, on: current.effort?.id == effort.id) {
                                    guard let selection = effort.selectionId else { return }
                                    Task { await model.select("model", selection) }
                                }
                            }
                        }
                        .groupedRow()
                    }
                    if !catalog.permissions.isEmpty {
                        Section("权限") {
                            ForEach(catalog.permissions) { option in
                                row(option, on: permissionSelection == option.selectionId) {
                                    guard let selection = option.selectionId else { return }
                                    Task { await model.select("permission", selection) }
                                }
                            }
                        }
                        .groupedRow()
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在读取电脑上的选项…").foregroundStyle(Palette.secondary)
                    }
                    .groupedRow()
                }
            }
            .groupedList()
            .disabled(model.working)
            .navigationTitle("模型与权限")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
        }
        .tint(Palette.ink)
        .presentationDetents([.medium, .large])
        .task { await model.loadCatalog(force: true) }
    }

    private func groups(_ models: [RemoteModelOption]) -> [(name: String?, models: [RemoteModelOption])] {
        var order: [String?] = []
        var byName: [String?: [RemoteModelOption]] = [:]
        for option in models {
            if byName[option.group] == nil { order.append(option.group) }
            byName[option.group, default: []].append(option)
        }
        return order.map { ($0, byName[$0] ?? []) }
    }

    private func row(_ option: RemoteOption, on: Bool, pick: @escaping () -> Void) -> some View {
        Button { Haptics.select(); pick() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name).font(.callout).foregroundStyle(option.enabled ? Palette.ink : Palette.faint)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if on { Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink) }
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.enabled)
        // The choice in force stays at full strength; tapping it again does nothing.
        .allowsHitTesting(!on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Where a remote session lives: its agent, its computer, its folder.
struct RemoteInfoSheet: View {
    let model: RemoteSessionModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let meta = model.meta {
                    Section {
                        line("智能体", meta.agentLabel)
                        line("电脑", app.remote.deviceName(of: meta) + (meta.deviceOnline ? "" : String(localized: "（离线）")))
                        line("项目", app.remote.place(of: meta))
                        if let cwd = meta.cwd, !cwd.isEmpty { line("目录", cwd) }
                        if let label = model.modelLabel { line("模型", label) }
                        if let label = model.permissionLabel { line("权限", label) }
                        line("模式", meta.takeover ? String(localized: "已接管，可以从这里发消息") : String(localized: "只读，在电脑上进行"))
                    }
                    .groupedRow()
                    Section {
                        Button { copyToPasteboard(meta.id); app.showToast(String(localized: "已复制"), tone: .success) } label: {
                            Label("复制会话 ID", systemImage: "doc.on.doc").foregroundStyle(Palette.ink)
                        }
                        if let server = app.remote.account?.server {
                            Button { InAppSafari.open(server) } label: {
                                Label("在 Agents Anywhere 网页版中查看", systemImage: "safari").foregroundStyle(Palette.ink)
                            }
                        }
                    } footer: {
                        Text("目标模式、终端和导出等功能在 Agents Anywhere 里。")
                    }
                    .groupedRow()
                }
            }
            .groupedList()
            .navigationTitle("会话信息")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
        }
        .tint(Palette.ink)
        .presentationDetents([.medium, .large])
        .task { await model.loadCatalog() }
    }

    private func line(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(Palette.secondary)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

/// The files the loaded turns changed, each with its diff: the workbench's 改动 for a remote session.
struct RemoteChangesSheet: View {
    let model: RemoteSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let changes = FileChange.collect(model.blocks, root: model.cwd)
        NavigationStack {
            Group {
                if changes.isEmpty {
                    ContentUnavailableView("还没有改动", systemImage: "doc.text.magnifyingglass", description: Text("智能体改过的文件会显示在这里。"))
                } else {
                    List {
                        Section {
                            ForEach(changes) { change in
                                NavigationLink(value: change) { ChangedFileRow(change: change) }
                                    .contextMenu {
                                        Button { copyToPasteboard(change.path) } label: { Label("复制路径", systemImage: "doc.on.doc") }
                                    }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Text("\(changes.count) 个文件")
                                ChangeCounts(added: changes.reduce(0) { $0 + $1.added }, removed: changes.reduce(0) { $0 + $1.removed })
                            }
                            .font(.footnote)
                            .textCase(nil)
                        }
                        .groupedRow()
                    }
                    .groupedList()
                }
            }
            .background(Palette.background)
            .navigationTitle("改动的文件")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
            .navigationDestination(for: FileChange.self) { change in
                ScrollView {
                    DiffLinesView(lines: change.lines, wrap: true).padding(12)
                }
                .background(Palette.background)
                .navigationTitle(change.name)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .tint(Palette.ink)
    }
}

/// The session's folder on the computer, read through the account's server: folders to walk
/// and text files to read. Nothing is written, and nothing is kept on the phone.
struct RemoteFilesSheet: View {
    let deviceId: String
    let root: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RemoteDirectoryPage(deviceId: deviceId, root: root, path: root, title: (root as NSString).lastPathComponent)
                .closeButton(dismiss)
                .navigationDestination(for: RemoteFileEntry.self) { entry in
                    if entry.isDirectory {
                        RemoteDirectoryPage(deviceId: deviceId, root: root, path: entry.path, title: entry.name)
                    } else {
                        RemoteFilePage(deviceId: deviceId, root: root, entry: entry)
                    }
                }
        }
        .tint(Palette.ink)
    }
}

private struct RemoteDirectoryPage: View {
    let deviceId: String
    let root: String
    let path: String
    let title: String
    @Environment(AppModel.self) private var app
    @State private var entries: [RemoteFileEntry]?
    @State private var failure: String?

    var body: some View {
        Group {
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView("空文件夹", systemImage: "folder")
                } else {
                    List(entries) { entry in
                        NavigationLink(value: entry) {
                            HStack(spacing: 12) {
                                Image(systemName: entry.isDirectory ? "folder" : "doc").foregroundStyle(Palette.secondary).frame(width: 22)
                                Text(entry.name).font(.callout).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                if let size = entry.size, !entry.isDirectory {
                                    Text(Int64(size).formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(Palette.faint)
                                }
                            }
                            .frame(minHeight: 34)
                        }
                        .groupedRow()
                    }
                    .groupedList()
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("读不到这个文件夹", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if entries == nil { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = app.remote.client else { return }
        failure = nil
        do {
            let value = try await client.post("/connectors/\(RemoteClient.encode(deviceId))/fs/list", ["root": .string(root), "path": .string(path)])
            guard value["ok"].bool != false else {
                throw RemoteError(kind: .rejected, message: value["error"]["message"].string ?? String(localized: "电脑没有返回这个文件夹"))
            }
            entries = value["result"]["entries"].array.compactMap(RemoteFileEntry.init).sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        } catch {
            failure = RemoteError(error).message
        }
    }
}

private struct RemoteFilePage: View {
    let deviceId: String
    let root: String
    let entry: RemoteFileEntry
    @Environment(AppModel.self) private var app
    @State private var text: String?
    @State private var truncated = false
    @State private var failure: String?
    @State private var rendered = true

    private var isMarkdown: Bool { ["md", "markdown"].contains((entry.name as NSString).pathExtension.lowercased()) }

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if truncated {
                            Text("文件较大，只显示开头的 1 MB。").font(.footnote).foregroundStyle(Palette.secondary)
                        }
                        if isMarkdown, rendered {
                            MarkdownView(text: text).modifier(LinkOpening())
                        } else {
                            Text(text).font(.system(.footnote, design: .monospaced)).foregroundStyle(Palette.ink).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
            } else if let failure {
                ContentUnavailableView("打不开这个文件", systemImage: "doc.questionmark", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let text {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isMarkdown {
                        Button { rendered.toggle() } label: { Image(systemName: rendered ? "chevron.left.forwardslash.chevron.right" : "doc.richtext") }
                            .accessibilityLabel(rendered ? "查看源文本" : "查看排版")
                    }
                    Button { copyToPasteboard(text) } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("复制")
                }
            }
        }
        .task { if text == nil { await load() } }
    }

    private func load() async {
        guard let client = app.remote.client else { return }
        do {
            let value = try await client.post("/connectors/\(RemoteClient.encode(deviceId))/fs/readText",
                                              ["path": .string(entry.path), "maxBytes": 1_048_576], query: ["root": root])
            if value["binary"].bool == true {
                failure = String(localized: "这不是文本文件，请在电脑上查看。")
                return
            }
            truncated = value["truncated"].bool ?? false
            text = value["content"].string ?? ""
        } catch {
            failure = RemoteError(error).message
        }
    }
}
