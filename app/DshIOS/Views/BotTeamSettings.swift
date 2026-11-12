import SwiftUI

/// What the whole Bot team shares: connectors, capabilities, keys, the mailbox, and how much
/// it has used. Each Bot's own page switches these on or off for it.
struct BotTeamSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var releasing: JSON?

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
                Toggle(isOn: Binding(get: { team.showsThinking }, set: { on in Task { await team.setPrefs(["thinking": .bool(on)]) } })) {
                    Label("显示思考过程", systemImage: "brain")
                }
                Picker(selection: Binding(get: { team.prefs["defaultBotModel"].string ?? "" }, set: { ref in
                    Task { await team.setPrefs(["defaultBotModel": ref.isEmpty ? .null : .string(ref)]) }
                })) {
                    Text(team.team["defaultModel"].string.flatMap(team.modelName).map { String(localized: "跟随 DSH（\($0)）") } ?? String(localized: "跟随 DSH")).tag("")
                    ForEach(team.models.compactMap { item in item["ref"].string.map { (ref: $0, name: item["name"].string ?? $0) } }, id: \.ref) { item in
                        Text(item.name).tag(item.ref)
                    }
                } label: { Label("新 Bot 的默认模型", systemImage: "cpu") }
                .pickerValueTint()
            } header: {
                Text("偏好")
            } footer: {
                Text("打开后，Bot 回复的步骤里会带上它的思考和用时。这两项和网页版共用。")
            }
            .groupedRow()
            if !team.privateArchives.isEmpty {
                Section {
                    ForEach(team.privateArchives, id: \.["id"]) { archive in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(archive["name"].string ?? "")
                                if let path = archive["workDir"].string { Text(EnginePaths.display(path)).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.head) }
                            }
                            Spacer()
                            Button("解除") { releasing = archive }.buttonStyle(.borderless)
                        }
                    }
                } header: { Text("已删除的私有 Bot") } footer: { Text("私有 Bot 删除后，它的文件夹、记忆和聊天记录仍然不让别的 Bot 碰。解除之后，文件夹可以再交给别的 Bot 用。") }
                .groupedRow()
            }
            Section {
                NavigationLink { BotUsagePage() } label: { Label("用量", systemImage: "chart.bar") }
                NavigationLink { BotWorkspacePage() } label: { Label("团队工作区", systemImage: "folder") }
                NavigationLink { BotDiagnosticsPage() } label: { Label("问题诊断", systemImage: "stethoscope") }
            }
            .groupedRow()
            Section {
                Link(destination: BotModel.projectURL) {
                    LabeledContent {
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                    } label: {
                        Label("DS Bot 项目主页", systemImage: "heart")
                    }
                }
                .foregroundStyle(Palette.ink)
            } footer: {
                Text("Bot 功能的后台是开源项目 DS Bot（Apache-2.0），感谢 Fei2411 和社区贡献者。")
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle("团队设置")
        .navigationBarTitleDisplayMode(.large)
        .task { await team.refreshState() }
        .confirmationDialog("解除对\(releasing?["name"].string ?? "")的封存？", isPresented: Binding(get: { releasing != nil }, set: { if !$0 { releasing = nil } }), titleVisibility: .visible) {
            Button("解除", role: .destructive) {
                if let id = releasing?["id"] { Task { await team.run("private-release", ["id": id]) } }
            }
        } message: { Text("它留下的文件不会删除，但别的 Bot 之后可以在那个文件夹里工作、读到里面的内容。") }
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
                    .pickerValueTint()
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
    @State private var imapPort = ""
    @State private var smtpPort = ""
    @State private var imapTls = true
    @State private var smtpTls = true
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
                        TextField("IMAP 端口（默认 993）", text: $imapPort).keyboardType(.numberPad)
                        Toggle("IMAP 用加密连接", isOn: $imapTls)
                        TextField("SMTP 服务器", text: $smtpHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("SMTP 端口（默认 465）", text: $smtpPort).keyboardType(.numberPad)
                        Toggle("SMTP 用加密连接", isOn: $smtpTls)
                    }
                } footer: { Text("常见邮箱会自动识别，其他邮箱请手动填写。") }
            }
            .navigationTitle("添加邮箱")
            .navigationBarTitleDisplayMode(.inline)
            .saveToolbar(canSave: address.contains("@") && !password.isEmpty, saving: saving, cancel: { dismiss() }) {
                saving = true
                Task {
                    var payload: [String: JSON] = ["address": .string(address), "password": .string(password)]
                    if custom {
                        payload["provider"] = "other"
                        payload["imapHost"] = .string(imapHost)
                        payload["smtpHost"] = .string(smtpHost)
                        if let port = Double(imapPort) { payload["imapPort"] = .number(port) }
                        if let port = Double(smtpPort) { payload["smtpPort"] = .number(port) }
                        payload["imapTls"] = .bool(imapTls)
                        payload["smtpTls"] = .bool(smtpTls)
                    }
                    if await app.botTeam.run("mail-account-add", payload) { dismiss() }
                    saving = false
                }
            }
        }
    }
}
