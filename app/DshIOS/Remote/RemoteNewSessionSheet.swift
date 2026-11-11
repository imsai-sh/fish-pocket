import SwiftUI

/// Where a new remote session should start, as far as the asker knows.
struct RemoteSessionTarget: Identifiable, Equatable {
    let id = UUID()
    var deviceId: String?
    var agentId: String?
    var projectId: String?
}

/// Start a session on a computer: which one, which agent, which folder, and the first message.
/// The agent's model and permission are its own defaults unless changed here.
struct RemoteNewSessionSheet: View {
    let target: RemoteSessionTarget
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var deviceId = ""
    @State private var agentId = ""
    @State private var projectId = ""
    @State private var path = ""
    @State private var text = ""
    @State private var catalog = RemoteCatalog()
    @State private var modelChoice = ""
    @State private var permissionChoice = ""
    /// The agent wants its folder prepared first, which only Agents Anywhere's own apps do.
    @State private var needsPreparation = false
    @State private var preparing = false
    @State private var creating = false
    @State private var failure: String?
    @FocusState private var typing: Bool

    private static let otherFolder = "\u{0}other"

    private var remote: RemoteStore { app.remote }
    private var device: RemoteDevice? { remote.device(deviceId) }
    private var agents: [RemoteAgent] { remote.agents(on: deviceId) }
    private var agent: RemoteAgent? { agents.first { $0.id == agentId } }
    private var projects: [RemoteProject] {
        remote.projects.filter { $0.deviceId == deviceId }.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }
    private var folder: String {
        projectId == Self.otherFolder ? path.trimmingCharacters(in: .whitespacesAndNewlines) : remote.project(projectId)?.path ?? ""
    }
    private var canStart: Bool {
        !creating && !preparing && !needsPreparation && device?.online == true && agent?.ready == true
            && !folder.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("电脑", selection: $deviceId) {
                        ForEach(remote.devices) { device in
                            Text(device.online ? device.name : String(localized: "\(device.name)（离线）")).tag(device.id)
                        }
                    }
                    Picker("智能体", selection: $agentId) {
                        if agents.isEmpty { Text("无").tag("") }
                        ForEach(agents) { agent in
                            Text(agent.ready ? agent.name : "\(agent.name) · \(agent.statusText)").tag(agent.id)
                        }
                    }
                    Picker("项目", selection: $projectId) {
                        ForEach(projects) { project in Text(project.name).tag(project.id) }
                        Text("其他文件夹…").tag(Self.otherFolder)
                    }
                    if projectId == Self.otherFolder {
                        TextField("电脑上的完整路径，如 /Users/me/project", text: $path)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                    } else if !folder.isEmpty {
                        Text(folder).font(.caption.monospaced()).foregroundStyle(Palette.secondary).lineLimit(2)
                    }
                } footer: {
                    if device?.online == false {
                        Text("这台电脑离线，开机并打开 Agents Anywhere 后才能新建会话。")
                    } else if agents.isEmpty, !deviceId.isEmpty {
                        Text("这台电脑上还没有智能体，请在电脑上的 Agents Anywhere 里添加。")
                    } else if let agent, !agent.ready {
                        Text(agent.reason ?? String(localized: "这个智能体还没有就绪。"))
                    }
                }
                .tint(.secondary)
                .groupedRow()

                if needsPreparation {
                    Section {
                        Text("这种智能体要先准备工作区，新会话请在 Agents Anywhere 里创建；创建后会出现在这里。").font(.subheadline).foregroundStyle(Palette.secondary)
                        Button { openURL(RemoteStore.Links.app) } label: { Label("打开 Agents Anywhere", systemImage: "arrow.up.forward.app").foregroundStyle(Palette.ink) }
                    }
                    .groupedRow()
                } else if !catalog.models.isEmpty || !catalog.permissions.isEmpty {
                    Section {
                        if !catalog.models.isEmpty {
                            Picker("模型", selection: $modelChoice) {
                                ForEach(modelChoices, id: \.selection) { choice in Text(choice.name).tag(choice.selection) }
                            }
                        }
                        if !catalog.permissions.isEmpty {
                            Picker("权限", selection: $permissionChoice) {
                                ForEach(catalog.permissions.filter { $0.enabled && $0.selectionId != nil }) { option in
                                    Text(option.name).tag(option.selectionId ?? "")
                                }
                            }
                        }
                    }
                    .tint(.secondary)
                    .groupedRow()
                }

                Section {
                    TextField("要它做什么", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($typing)
                } footer: {
                    if let failure { Text(failure).foregroundStyle(Palette.removed) }
                }
                .groupedRow()
            }
            .groupedList()
            .navigationTitle("在电脑上新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if creating { ProgressView() } else { Button("开始", action: start).disabled(!canStart) }
                }
            }
        }
        .tint(Palette.ink)
        .interactiveDismissDisabled(creating)
        .onAppear(perform: seed)
        .onChange(of: deviceId) { deviceChanged() }
        .task(id: deviceId) { if !deviceId.isEmpty { await remote.loadAgents(on: deviceId); pickAgent() } }
        .task(id: "\(deviceId)/\(agentId)") { await prepare() }
    }

    /// One row per model, or per level of a model that has several.
    private var modelChoices: [(name: String, selection: String)] {
        catalog.models.filter(\.option.enabled).flatMap { model -> [(name: String, selection: String)] in
            let levels = model.efforts.filter { $0.enabled }
            if levels.isEmpty { return model.option.selectionId.map { [(model.option.name, $0)] } ?? [] }
            return levels.map { ("\(model.option.name) · \($0.name)", $0.selectionId ?? "") }.filter { !$0.selection.isEmpty }
        }
    }

    private func seed() {
        deviceId = target.deviceId ?? remote.devices.first(where: \.online)?.id ?? remote.devices.first?.id ?? ""
        agentId = target.agentId ?? ""
        pickAgent()
        pickProject(preferring: target.projectId)
        typing = true
    }

    private func deviceChanged() {
        if agent == nil { agentId = "" }
        pickAgent()
        if remote.project(projectId)?.deviceId != deviceId, projectId != Self.otherFolder { pickProject(preferring: nil) }
    }

    private func pickAgent() {
        if agent == nil { agentId = agents.first(where: \.ready)?.id ?? agents.first?.id ?? "" }
    }

    private func pickProject(preferring id: String?) {
        if let id, remote.project(id)?.deviceId == deviceId { projectId = id } else { projectId = projects.first?.id ?? Self.otherFolder }
    }

    /// What the chosen agent offers for a new session: its models and permissions, and their defaults.
    private func prepare() async {
        catalog = RemoteCatalog()
        modelChoice = ""
        permissionChoice = ""
        needsPreparation = false
        guard let client = remote.client, let agent, agent.ready, device?.online == true else { return }
        preparing = true
        defer { preparing = false }
        let base = "/connectors/\(RemoteClient.encode(deviceId))/runtimes/\(RemoteClient.encode(agent.id))"
        guard let value = try? await client.get("\(base)/capabilities"), !Task.isCancelled else { return }
        let capabilities = RemoteCapabilities(value["capabilitySet"])
        needsPreparation = capabilities.allows("runtime.workspace.prepare")
        var next = RemoteCatalog()
        if capabilities.allows("catalog.model"), let models = try? await client.get("\(base)/catalogs/model") {
            next.models = models["catalog"]["models"].array.compactMap(RemoteModelOption.init)
        }
        if capabilities.allows("catalog.permission"), let permissions = try? await client.get("\(base)/catalogs/permission") {
            next.permissions = permissions["catalog"]["permissions"].array.compactMap(RemoteOption.init)
        }
        guard !Task.isCancelled else { return }
        catalog = next
        let usable = next.models.filter(\.option.enabled)
        modelChoice = (usable.first { $0.option.isDefault } ?? usable.first)?.selection() ?? ""
        let allowed = next.permissions.filter { $0.enabled && $0.selectionId != nil }
        permissionChoice = (allowed.first { $0.isDefault } ?? allowed.first)?.selectionId ?? ""
    }

    private func start() {
        guard canStart, let client = remote.client, let agent else { return }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = true
        failure = nil
        typing = false
        Task {
            defer { creating = false }
            var submitted = false
            do {
                let project = try await remote.project(on: deviceId, path: folder)
                var selections: [String: JSON] = [:]
                if !modelChoice.isEmpty { selections["model"] = .string(modelChoice) }
                if !permissionChoice.isEmpty { selections["permission"] = .string(permissionChoice) }
                submitted = true
                let value = try await client.post("/sessions/create-and-start", [
                    "connectorId": .string(deviceId), "projectId": .string(project.id), "runtime": .string(agent.type), "runtimeId": .string(agent.id),
                    "cwd": .string(project.path), "content": .string(message), "selections": .object(selections), "runtimeOptions": [:],
                    "attachments": [], "clientMessageId": .string(UUID().uuidString),
                ])
                guard let id = value["session"]["id"].string else {
                    throw RemoteError(kind: .invalid, message: String(localized: "服务器返回了无法识别的内容"))
                }
                remote.upsert(value["session"])
                Haptics.success()
                dismiss()
                app.open(session: RemoteStore.selection(id))
            } catch {
                let problem = RemoteError(error)
                Haptics.error()
                // Past this point the session may exist: say so rather than invite a second one.
                failure = submitted && !problem.definite
                    ? String(localized: "不确定会话是否已创建，请先看看会话列表，避免重复创建。\(problem.message)")
                    : problem.message
            }
        }
    }
}
