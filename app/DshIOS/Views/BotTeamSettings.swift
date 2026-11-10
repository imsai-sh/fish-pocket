import SwiftUI

/// What the whole Bot team shares: connectors, capabilities, keys, the mailbox, and how much
/// it has used. Each Bot's own page switches these on or off for it.
struct BotTeamSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let team = app.botTeam
        List {
            Section {
                NavigationLink { BotConnectorsPage() } label: {
                    LabeledContent { Text("\(team.connectors.filter { $0["state"].string == "ready" }.count) 个已连接") } label: {
                        Label("连接器", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                NavigationLink { BotCapabilitiesPage() } label: {
                    LabeledContent { Text("\(team.capabilities.count) 个") } label: { Label("能力", systemImage: "puzzlepiece") }
                }
                NavigationLink { BotSecretsPage() } label: {
                    LabeledContent { Text("\(team.secrets.count) 个") } label: { Label("密钥", systemImage: "key") }
                }
                NavigationLink { BotMailPage() } label: {
                    LabeledContent { Text("\(team.mail["accounts"].array.count) 个邮箱") } label: { Label("邮箱", systemImage: "envelope") }
                }
                NavigationLink { BotIMPage() } label: {
                    LabeledContent { Text("\(team.team["im"]["connections"].array.count) 个") } label: { Label("聊天软件", systemImage: "message") }
                }
            } footer: {
                Text("连接器、能力和密钥整个团队共用，每个 Bot 能用哪些在它自己的资料页里开关。")
            }
            .groupedRow()
            Section {
                NavigationLink { BotUsagePage() } label: { Label("用量", systemImage: "chart.bar") }
                NavigationLink { BotWorkspacePage() } label: { Label("团队工作区", systemImage: "folder") }
                NavigationLink { BotDiagnosticsPage() } label: { Label("问题诊断", systemImage: "stethoscope") }
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle("团队设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await team.refreshState() }
    }
}

// MARK: - Connectors

/// Services the Bots can use through MCP: signed in once, shared by the team.
struct BotConnectorsPage: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    private static let order = ["dev", "docs", "work", "design", "data", "commerce", "search", "custom"]

    var body: some View {
        let team = app.botTeam
        let rows = team.connectors
        List {
            ForEach(Self.order, id: \.self) { category in
                let group = rows.filter { ($0["category"].string ?? "custom") == category }
                if !group.isEmpty {
                    Section(Self.title(category)) {
                        ForEach(group, id: \.["id"]) { row in
                            NavigationLink { BotConnectorPage(id: row["id"].string ?? "") } label: { ConnectorRow(row: row) }
                        }
                    }
                    .groupedRow()
                }
            }
            Section {
                Button { adding = true } label: { Label("添加自定义连接器", systemImage: "plus") }
            } footer: {
                Text("连接器是 MCP 服务。iOS 上只能用网址形式的连接器，需要启动本地命令的那种只能在电脑上用。")
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle("连接器")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { CustomConnectorSheet() }
        .task { await team.refreshState() }
    }

    static func title(_ category: String) -> String {
        switch category {
        case "dev": String(localized: "开发")
        case "docs": String(localized: "文档与资料")
        case "work": String(localized: "协作办公")
        case "design": String(localized: "设计")
        case "data": String(localized: "数据")
        case "commerce": String(localized: "支付与电商")
        case "search": String(localized: "搜索")
        default: String(localized: "自定义")
        }
    }
}

private struct ConnectorRow: View {
    let row: JSON

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row["name"].string ?? "").foregroundStyle(Palette.ink)
                if let about = row["about"].string { Text(about).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            ConnectorState(row: row)
        }
    }
}

struct ConnectorState: View {
    let row: JSON

    var body: some View {
        let (text, color): (String, Color) = switch row["state"].string {
        case "ready": (row["account"].string ?? String(localized: "已连接"), Palette.added)
        case "connecting": (String(localized: "连接中"), Palette.running)
        case "error": (String(localized: "出错"), Palette.removed)
        case "needs-client", "needs-sign-in": (String(localized: "需要登录"), Palette.waiting)
        default: (String(localized: "未连接"), Palette.faint)
        }
        Text(text).font(.caption).foregroundStyle(color).lineLimit(1)
    }
}

/// One connector: connect it the way it signs in, then which Bots may use it.
struct BotConnectorPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var key = ""
    @State private var token = ""
    @State private var pasted = ""
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var busy = false

    var body: some View {
        let team = app.botTeam
        let row = team.connector(id) ?? .null
        let state = row["state"].string ?? "off"
        let kind = row["auth"]["kind"].string ?? "none"
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(row["name"].string ?? id).font(.headline)
                        Spacer()
                        ConnectorState(row: row)
                    }
                    if let about = row["about"].string { Text(about).font(.footnote).foregroundStyle(Palette.secondary) }
                    if let error = row["error"].string, state == "error" { Text(BotErrorText.text(error)).font(.footnote).foregroundStyle(Palette.removed) }
                }
                .padding(.vertical, 4)
            }
            .groupedRow()

            if state == "ready" || state == "connecting" && row["pending"].isNull {
                connected(row)
            } else if let pending = row["pending"].nonNull {
                signingIn(pending)
            } else if state == "needs-client" {
                Section {
                    TextField("Client ID", text: $clientId).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Client Secret（可不填）", text: $clientSecret)
                    Button("继续登录") { run("connector-client", ["id": .string(id), "clientId": .string(clientId), "clientSecret": .string(clientSecret)]) }
                        .disabled(clientId.isEmpty || busy)
                } footer: { Text("这个服务需要你自己的 OAuth 应用。在服务的开发者后台创建后，把 Client ID 填在这里。") }
                .groupedRow()
            } else {
                switch kind {
                case "none":
                    Section { Button("连接") { run("connector-connect", ["id": .string(id)]) }.disabled(busy) } footer: { Text("不需要登录，连上就能用。") }
                        .groupedRow()
                case "key":
                    Section {
                        SecureField("API Key", text: $key)
                        Button("保存并连接") { run("connector-connect", ["id": .string(id), "key": .string(key)]) }.disabled(key.isEmpty || busy)
                        if let url = row["auth"]["keyUrl"].string.flatMap(URL.init(string:)) { Link("去申请 Key", destination: url) }
                    }
                    .groupedRow()
                default:
                    Section {
                        Button(id == "github" ? "用 GitHub 账号登录" : "登录") { run("connector-connect", ["id": .string(id)]) }.disabled(busy)
                    } footer: {
                        Text("会在 App 里打开登录页面，登录完回到这里。")
                    }
                    .groupedRow()
                    if id == "github" {
                        Section {
                            SecureField("Personal Access Token", text: $token)
                            Button("用令牌连接") { run("connector-connect", ["id": .string(id), "token": .string(token)]) }.disabled(token.isEmpty || busy)
                        } header: { Text("或者粘贴令牌") }
                        .groupedRow()
                    }
                }
            }
            if row["custom"].bool == true {
                Section {
                    Button("移除这个连接器", role: .destructive) {
                        Task { if await call("connector-remove", ["id": .string(id)]) { dismiss() } }
                    }
                }
                .groupedRow()
            }
        }
        .groupedList()
        .disabled(busy)
        .navigationTitle(row["name"].string ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: row["pending"]["url"].string) { _, url in
            // A browser sign-in: the page runs inside the app so the engine, which listens for
            // the redirect, keeps running.
            if let url = url.flatMap(URL.init(string:)) { InAppSafari.open(url) }
        }
    }

    @ViewBuilder
    private func connected(_ row: JSON) -> some View {
        let team = app.botTeam
        let off = Set(row["offFor"].array.compactMap(\.string))
        Section {
            ForEach(team.bots) { bot in
                Toggle(isOn: Binding(get: { !off.contains(bot.id) }, set: { on in
                    var next = off
                    if on { next.remove(bot.id) } else { next.insert(bot.id) }
                    run("connector-set", ["id": .string(id), "offFor": .array(next.sorted().map(JSON.string))])
                })) {
                    HStack(spacing: 10) { BotAvatar(bot: bot, size: 26); Text(bot.name) }
                }
            }
        } header: { Text("哪些 Bot 可以用") }
        .groupedRow()
        if !row["readOnly"].isNull {
            Section {
                Toggle("只读", isOn: Binding(get: { row["readOnly"].bool ?? false }, set: { run("connector-set", ["id": .string(id), "readOnly": .bool($0)]) }))
            } footer: { Text("只读时 Bot 只能查询，不能修改这个服务里的内容。") }
            .groupedRow()
        }
        Section {
            if row["state"].string == "error" { Button("重试") { run("connector-retry", ["id": .string(id)]) } }
            Button("断开连接", role: .destructive) { run("connector-disconnect", ["id": .string(id)]) }
        }
        .groupedRow()
    }

    @ViewBuilder
    private func signingIn(_ pending: JSON) -> some View {
        if pending["kind"].string == "device" {
            Section {
                LabeledContent("验证码", value: pending["userCode"].string ?? "")
                Button("复制验证码并打开网页") {
                    copyToPasteboard(pending["userCode"].string ?? "")
                    if let url = pending["verificationUri"].string.flatMap(URL.init(string:)) { InAppSafari.open(url) }
                }
                Button("取消") { run("connector-cancel", ["id": .string(id)]) }
            } footer: { Text("在打开的网页里粘贴验证码并授权，这里会自动连上。") }
            .groupedRow()
        } else {
            Section {
                if let url = pending["url"].string.flatMap(URL.init(string:)) { Button("打开登录页面") { InAppSafari.open(url) } }
                Button("取消") { run("connector-cancel", ["id": .string(id)]) }
            }
            .groupedRow()
            Section {
                TextField("登录完成后地址栏里的网址", text: $pasted, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("完成登录") { run("connector-sign-in-code", ["id": .string(id), "input": .string(pasted)]) }.disabled(pasted.isEmpty)
            } footer: { Text("登录后页面没有自动回来的话，把最后那个网址整段粘贴到这里。") }
            .groupedRow()
        }
    }

    private func run(_ endpoint: String, _ payload: [String: JSON]) {
        Task { _ = await call(endpoint, payload) }
    }

    @discardableResult
    private func call(_ endpoint: String, _ payload: [String: JSON]) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let value = try await app.botTeam.call(endpoint, .object(payload))
            app.botTeam.applyConnectors(value)
            await app.botTeam.refreshState()
            return true
        } catch {
            app.showToast(BotErrorText.text(error.localizedDescription), tone: .warning)
            return false
        }
    }
}

/// A connector of the user's own: an MCP server at an HTTPS address.
private struct CustomConnectorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var headers = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字", text: $name)
                    TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    TextField("Authorization: Bearer …", text: $headers, axis: .vertical).lineLimit(2...).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("请求头（可不填）") } footer: { Text("一行一个，写成「名字: 值」。值可以写 $DSH_SECRET_名字，引用保存的密钥。") }
            }
            .navigationTitle("自定义连接器")
            .navigationBarTitleDisplayMode(.inline)
            .saveToolbar(canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty && url.hasPrefix("http"), saving: saving, cancel: { dismiss() }) {
                saving = true
                Task {
                    var fields: [String: JSON] = [:]
                    for line in headers.split(separator: "\n") {
                        guard let colon = line.firstIndex(of: ":") else { continue }
                        fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = .string(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                    }
                    do {
                        let value = try await app.botTeam.call("connector-add", ["name": .string(name), "url": .string(url), "headers": .object(fields)])
                        app.botTeam.applyConnectors(value)
                        dismiss()
                    } catch {
                        app.showToast(BotErrorText.text(error.localizedDescription), tone: .warning)
                    }
                    saving = false
                }
            }
        }
    }
}

// MARK: - Capabilities

/// The team's capability library: MCP servers, skills and packs a Bot can be given.
struct BotCapabilitiesPage: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    var body: some View {
        let team = app.botTeam
        List {
            if team.capabilities.isEmpty {
                Section { Text("还没有能力。能力可以是一个 MCP 服务、一段技能说明，或者把几个打包在一起。").font(.footnote).foregroundStyle(Palette.secondary) }
                    .groupedRow()
            } else {
                Section {
                    ForEach(team.capabilities, id: \.["name"]) { item in
                        NavigationLink { BotCapabilityEditor(original: item) } label: { BotCapabilityRow(item: item) }
                            .swipeActions {
                                Button("删除", role: .destructive) { Task { await team.run("capability-delete", ["name": item["name"]]) } }
                            }
                    }
                } footer: { Text("在每个 Bot 的资料页里打开开关，它才会用上。左滑可以删除。") }
                .groupedRow()
            }
            Section { Button { adding = true } label: { Label("新建能力", systemImage: "plus") } }
                .groupedRow()
        }
        .groupedList()
        .navigationTitle("能力")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { NavigationStack { BotCapabilityEditor(original: nil) } }
    }
}

struct BotCapabilityRow: View {
    let item: JSON

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(item["name"].string ?? "").foregroundStyle(Palette.ink)
                Text(Self.kind(item)).font(.caption2).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Palette.control, in: Capsule())
            }
            if let detail = item["description"].string, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2) }
            if item["transport"].string == "stdio" { Text("需要在电脑上运行，iOS 上用不了").font(.caption2).foregroundStyle(Palette.waiting) }
        }
    }

    static func kind(_ item: JSON) -> String {
        switch item["kind"].string {
        case "skill": String(localized: "技能")
        case "pack": String(localized: "组合")
        default: String(localized: "MCP 服务")
        }
    }
}

/// Create or edit one capability. A stdio MCP (a local command) cannot run on iOS, so only
/// an HTTP one is offered; one made elsewhere still shows and can be edited.
struct BotCapabilityEditor: View {
    enum Kind: String, CaseIterable, Identifiable { case mcp, skill, pack; var id: String { rawValue } }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let original: JSON?
    @State private var name = ""
    @State private var kind = Kind.mcp
    @State private var detail = ""
    @State private var url = ""
    @State private var headers = ""
    @State private var content = ""
    @State private var items: Set<String> = []
    @State private var saving = false
    @State private var loaded = false

    var body: some View {
        let team = app.botTeam
        Form {
            Section {
                TextField("名字，比如 web-search", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(original != nil)
                if original == nil {
                    Picker("类型", selection: $kind) {
                        Text("MCP 服务").tag(Kind.mcp)
                        Text("技能").tag(Kind.skill)
                        Text("组合").tag(Kind.pack)
                    }
                }
                TextField("一句话说明它做什么", text: $detail, axis: .vertical)
            } footer: {
                if original == nil { Text("名字只能用小写字母、数字和连字符。") }
            }
            switch kind {
            case .mcp:
                if original?["transport"].string == "stdio" {
                    Section { Text("这个 MCP 服务要启动本地命令（\(original?["command"].string ?? "")），只能在电脑上运行。").font(.footnote).foregroundStyle(Palette.secondary) }
                } else {
                    Section {
                        TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("请求头，一行一个「名字: 值」", text: $headers, axis: .vertical).lineLimit(2...).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("服务地址") } footer: { Text("值可以写 $DSH_SECRET_名字，引用保存的密钥。") }
                }
            case .skill:
                Section("技能内容") { TextField("什么时候用、怎么做", text: $content, axis: .vertical).lineLimit(8...) }
            case .pack:
                Section {
                    ForEach(team.capabilities.filter { $0["kind"].string != "pack" && $0["name"].string != original?["name"].string }, id: \.["name"]) { item in
                        let itemName = item["name"].string ?? ""
                        Toggle(itemName, isOn: Binding(get: { items.contains(itemName) }, set: { if $0 { items.insert(itemName) } else { items.remove(itemName) } }))
                    }
                } header: { Text("包含") } footer: { Text("给 Bot 打开一个组合，就同时打开里面的每一项。") }
            }
        }
        .navigationTitle(original == nil ? "新建能力" : (original?["name"].string ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .saveToolbar(canSave: canSave, saving: saving, cancel: original == nil ? { dismiss() } : nil) { save() }
        .onAppear(perform: fill)
    }

    private var canSave: Bool {
        guard !name.isEmpty else { return false }
        switch kind {
        case .mcp: return original?["transport"].string == "stdio" || url.hasPrefix("http")
        case .skill: return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .pack: return !items.isEmpty
        }
    }

    private func fill() {
        guard !loaded, let original else { return }
        loaded = true
        name = original["name"].string ?? ""
        kind = Kind(rawValue: original["kind"].string ?? "mcp") ?? .mcp
        detail = original["description"].string ?? ""
        url = original["url"].string ?? ""
        headers = original["headers"].object.map { "\($0.key): \($0.value.string ?? "")" }.sorted().joined(separator: "\n")
        content = original["content"].string ?? ""
        items = Set(original["items"].array.compactMap(\.string))
    }

    private func save() {
        var payload: [String: JSON] = ["name": .string(name), "kind": .string(kind.rawValue), "description": .string(detail)]
        switch kind {
        case .mcp:
            if let original, original["transport"].string == "stdio" {
                payload["transport"] = "stdio"
                payload["command"] = original["command"]
                payload["args"] = original["args"]
                payload["env"] = original["env"]
            } else {
                var fields: [String: JSON] = [:]
                for line in headers.split(separator: "\n") {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = .string(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                }
                payload["transport"] = "streamable-http"
                payload["url"] = .string(url)
                payload["headers"] = .object(fields)
            }
        case .skill: payload["content"] = .string(content)
        case .pack: payload["items"] = .array(items.sorted().map(JSON.string))
        }
        saving = true
        Task {
            if await app.botTeam.run("capability-save", payload) { dismiss() }
            saving = false
        }
    }
}

// MARK: - Secrets

/// Keys the Bots use in their shell as `$DSH_SECRET_NAME`; the app never reads a value back.
struct BotSecretsPage: View {
    @Environment(AppModel.self) private var app
    @State private var editing: JSON?
    @State private var adding = false

    var body: some View {
        let team = app.botTeam
        List {
            if team.secrets.isEmpty {
                Section { Text("还没有保存密钥。Bot 需要时会在聊天里请你填写。").font(.footnote).foregroundStyle(Palette.secondary) }
                    .groupedRow()
            } else {
                Section {
                    ForEach(team.secrets, id: \.["name"]) { secret in
                        Button { editing = secret } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(secret["name"].string ?? "").font(.body.monospaced()).foregroundStyle(Palette.ink)
                                Text(Self.scope(secret, team: team)).font(.caption).foregroundStyle(Palette.secondary)
                                if let purpose = secret["purpose"].string, !purpose.isEmpty { Text(purpose).font(.caption).foregroundStyle(Palette.faint).lineLimit(2) }
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await team.run("secret-delete", ["name": secret["name"]]) } }
                        }
                    }
                } footer: { Text("密钥的值只存在这台设备上，App 和模型都读不到原文。左滑可以删除。") }
                .groupedRow()
            }
            Section { Button { adding = true } label: { Label("添加密钥", systemImage: "plus") } }
                .groupedRow()
        }
        .groupedList()
        .navigationTitle("密钥")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { editing.map(IdentifiedJSON.init) }, set: { editing = $0?.json })) { item in BotSecretSheet(original: item.json) }
        .sheet(isPresented: $adding) { BotSecretSheet(original: nil) }
    }

    @MainActor
    static func scope(_ secret: JSON, team: BotModel) -> String {
        if secret["scope"].string == "all" { return String(localized: "所有 Bot 可用") }
        let names = secret["scope"].array.compactMap { $0.string.flatMap(team.bot)?.name }
        return names.isEmpty ? String(localized: "没有 Bot 可用") : names.joined(separator: "、")
    }
}

struct IdentifiedJSON: Identifiable {
    let json: JSON
    var id: String { json["name"].string ?? json["id"].string ?? "" }
}

/// Add a key, or change who may use one (and replace its value).
private struct BotSecretSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let original: JSON?
    @State private var name = ""
    @State private var value = ""
    @State private var purpose = ""
    @State private var everyone = true
    @State private var bots: Set<String> = []
    @State private var saving = false

    var body: some View {
        let team = app.botTeam
        NavigationStack {
            Form {
                Section {
                    TextField("名字，比如 OPENAI_API_KEY", text: $name).textInputAutocapitalization(.characters).autocorrectionDisabled().disabled(original != nil)
                    SecureField(original == nil ? "值" : "新的值（不改就留空）", text: $value)
                    TextField("用途（可不填）", text: $purpose)
                }
                Section {
                    Toggle("所有 Bot 都能用", isOn: $everyone)
                    if !everyone {
                        ForEach(team.bots) { bot in
                            Toggle(bot.name, isOn: Binding(get: { bots.contains(bot.id) }, set: { if $0 { bots.insert(bot.id) } else { bots.remove(bot.id) } }))
                        }
                    }
                } header: { Text("谁能用") }
            }
            .navigationTitle(original == nil ? "添加密钥" : (original?["name"].string ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .saveToolbar(canSave: !name.isEmpty && (original != nil || value.count >= 4), saving: saving, cancel: { dismiss() }) { save() }
            .onAppear {
                guard let original else { return }
                name = original["name"].string ?? ""
                purpose = original["purpose"].string ?? ""
                everyone = original["scope"].string == "all"
                bots = Set(original["scope"].array.compactMap(\.string))
            }
        }
    }

    private func save() {
        let scope: JSON = everyone ? "all" : .array(bots.sorted().map(JSON.string))
        saving = true
        Task {
            var done = true
            if !value.isEmpty {
                done = await app.botTeam.run("secret-set", ["name": .string(name), "value": .string(value), "purpose": .string(purpose), "scope": scope])
            } else if original != nil {
                done = await app.botTeam.run("secret-update", ["name": .string(name), "purpose": .string(purpose), "scope": scope])
            }
            saving = false
            if done { dismiss() }
        }
    }
}

// MARK: - Mail

/// Mailboxes the Bots can read and send from (IMAP and SMTP with an app password).
struct BotMailPage: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false
    @State private var recipient = ""

    var body: some View {
        let team = app.botTeam
        let mail = team.mail
        List {
            Section {
                ForEach(mail["accounts"].array, id: \.["id"]) { account in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account["address"].string ?? "")
                        if account["state"].string == "error" {
                            Text(BotErrorText.text(account["error"].string ?? "")).font(.caption).foregroundStyle(Palette.removed)
                        }
                    }
                    .swipeActions {
                        Button("移除", role: .destructive) { mailCall("mail-account-remove", ["id": account["id"]]) }
                    }
                }
                Button { adding = true } label: { Label("添加邮箱", systemImage: "plus") }
            } header: { Text("邮箱") } footer: { Text("用邮箱的授权码或应用专用密码，不是登录密码。QQ、163、126、Gmail、iCloud 会自动填好服务器。") }
            .groupedRow()
            Section {
                ForEach(mail["allowedRecipients"].array.compactMap(\.string), id: \.self) { address in
                    Text(address).swipeActions {
                        Button("移除", role: .destructive) { mailCall("mail-rule-set", ["removeRecipient": .string(address)]) }
                    }
                }
                HStack {
                    TextField("收件人地址", text: $recipient).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("添加") { mailCall("mail-rule-set", ["addRecipient": .string(recipient)]); recipient = "" }.disabled(!recipient.contains("@"))
                }
            } header: { Text("可以直接发送的收件人") } footer: { Text("Bot 发给这些地址时不用你确认；发给其他人会先给你一张邮件卡片。") }
            .groupedRow()
            Section {
                let direct = Set(mail["noDraftFor"].array.compactMap(\.string))
                ForEach(team.bots) { bot in
                    Toggle(bot.name, isOn: Binding(get: { direct.contains(bot.id) }, set: { on in
                        mailCall("mail-rule-set", ["botId": .string(bot.id), "noDraft": .bool(on)])
                    }))
                }
            } header: { Text("发信不用确认的 Bot") }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle("邮箱")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { MailAccountSheet() }
        .task { await team.refreshState() }
    }

    private func mailCall(_ endpoint: String, _ payload: [String: JSON]) {
        Task {
            do {
                let view = try await app.botTeam.call(endpoint, .object(payload))
                var connectors = app.botTeam.live["connectors"] ?? ["connectors": []]
                if case .object(var object) = connectors { object["mail"] = view; connectors = .object(object) }
                app.botTeam.applyConnectors(connectors)
            } catch {
                app.showToast(BotErrorText.text(error.localizedDescription), tone: .warning)
            }
        }
    }
}

private struct MailAccountSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var password = ""
    @State private var custom = false
    @State private var imapHost = ""
    @State private var smtpHost = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("邮箱地址", text: $address).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("授权码或应用专用密码", text: $password)
                }
                Section {
                    Toggle("手动填写服务器", isOn: $custom)
                    if custom {
                        TextField("IMAP 服务器", text: $imapHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("SMTP 服务器", text: $smtpHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } footer: { Text("常见邮箱会自动识别，其他邮箱请手动填写，端口默认 993 和 465。") }
            }
            .navigationTitle("添加邮箱")
            .navigationBarTitleDisplayMode(.inline)
            .saveToolbar(canSave: address.contains("@") && !password.isEmpty, saving: saving, cancel: { dismiss() }) {
                saving = true
                Task {
                    var payload: [String: JSON] = ["address": .string(address), "password": .string(password)]
                    if custom { payload["provider"] = "other"; payload["imapHost"] = .string(imapHost); payload["smtpHost"] = .string(smtpHost) }
                    if await app.botTeam.run("mail-account-add", payload) { dismiss() }
                    saving = false
                }
            }
        }
    }
}

// MARK: - Errors

/// ds-bot answers in English; the messages people meet most often, in the app's words.
enum BotErrorText {
    private static let table: [(String, String)] = [
        ("Paste a key first", String(localized: "先粘贴 Key")),
        ("Paste a token first", String(localized: "先粘贴令牌")),
        ("GitHub did not accept this token", String(localized: "GitHub 不接受这个令牌")),
        ("Could not reach GitHub", String(localized: "连不上 GitHub")),
        ("Sign-in timed out", String(localized: "登录超时了")),
        ("No sign-in is waiting", String(localized: "没有等待中的登录")),
        ("The password was refused", String(localized: "密码被拒绝了。请用邮箱的授权码或应用专用密码。")),
        ("Could not reach the mail server", String(localized: "连不上邮件服务器")),
        ("Enter the IMAP and SMTP hosts", String(localized: "请填写 IMAP 和 SMTP 服务器")),
        ("A key must have at least 4 characters", String(localized: "密钥至少要 4 个字符")),
        ("A name uses capitals, digits, and underscores", String(localized: "名字只能用大写字母、数字和下划线，并以字母开头")),
        ("Use a capability name with lowercase letters", String(localized: "名字只能用小写字母、数字和单个连字符，也不能和连接器重名")),
        ("Enter a valid HTTP or HTTPS URL", String(localized: "请填写 http 或 https 开头的网址")),
        ("Connector addresses must start with https://", String(localized: "连接器地址要以 https:// 开头")),
        ("is not available", String(localized: "这个名字已经被占用了")),
        ("This request was already answered", String(localized: "这个请求已经处理过了")),
        ("This request is gone", String(localized: "这个请求已经不在了")),
        ("The Bot is working", String(localized: "Bot 正在干活，等它做完或先让它停下")),
        ("Automation tasks are off in DSH", String(localized: "自动化任务没有开启")),
    ]

    static func text(_ message: String) -> String {
        table.first { message.contains($0.0) }?.1 ?? message
    }
}
