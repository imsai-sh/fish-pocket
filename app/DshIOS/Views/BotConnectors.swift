import SwiftUI

// MARK: - Faces

/// How a connector is shown: the service's mark on its colour where Simple Icons has one
/// (`Assets.xcassets/Connectors`), else its initial on a colour picked here; and what it gives
/// a Bot, in the reader's language (ds-bot's own line is English).
enum ConnectorBrand {
    struct Look {
        /// The image in `Assets.xcassets/Connectors`; nil: the name's initial.
        var mark: String?
        var hex: String
        var about: String
    }

    static func look(_ id: String) -> Look? { looks[id] }

    /// What the connector is for: ours for the ones known here, ds-bot's for the rest.
    static func about(_ row: JSON) -> String {
        row["id"].string.flatMap(look)?.about ?? row["about"].string ?? ""
    }

    static func name(_ row: JSON) -> String {
        row["id"].string == "amap" ? String(localized: "高德地图") : row["name"].string ?? row["id"].string ?? ""
    }

    private static let looks: [String: Look] = [
        "github": Look(mark: "github", hex: "#181717", about: String(localized: "仓库、Issue 和拉取请求")),
        "notion": Look(mark: "notion", hex: "#000000", about: String(localized: "页面、数据库和知识库")),
        "linear": Look(mark: "linear", hex: "#5E6AD2", about: String(localized: "Issue、项目和迭代")),
        "atlassian": Look(mark: "atlassian", hex: "#0052CC", about: String(localized: "Jira 的 Issue 和 Confluence 页面")),
        "sentry": Look(mark: "sentry", hex: "#362D59", about: String(localized: "报错、链路和发布")),
        "stripe": Look(mark: "stripe", hex: "#635BFF", about: String(localized: "支付、发票和客户")),
        "paypal": Look(mark: "paypal", hex: "#002991", about: String(localized: "订单、付款和发票")),
        "square": Look(mark: "square", hex: "#3E4348", about: String(localized: "支付、订单和商品目录")),
        "cloudflare": Look(mark: "cloudflare", hex: "#F38020", about: String(localized: "Workers、DNS 和账号资源")),
        "vercel": Look(mark: "vercel", hex: "#000000", about: String(localized: "项目、部署和日志")),
        "supabase": Look(mark: "supabase", hex: "#3FCF8E", about: String(localized: "数据库、数据表和项目设置")),
        "neon": Look(mark: "neon", hex: "#34D59A", about: String(localized: "Postgres 数据库和分支")),
        "figma": Look(mark: "figma", hex: "#F24E1E", about: String(localized: "设计稿、组件和评论")),
        "canva": Look(hex: "#00C4CC", about: String(localized: "设计、文件夹和导出")),
        "intercom": Look(mark: "intercom", hex: "#6AFDEF", about: String(localized: "对话、联系人和文章")),
        "monday": Look(hex: "#FF3D57", about: String(localized: "看板、条目和流程")),
        "webflow": Look(mark: "webflow", hex: "#146EF5", about: String(localized: "站点、页面和 CMS 内容")),
        "wix": Look(mark: "wix", hex: "#0C6EFC", about: String(localized: "站点、页面和站点内容")),
        "netlify": Look(mark: "netlify", hex: "#00C7B7", about: String(localized: "站点、部署和表单")),
        "airtable": Look(mark: "airtable", hex: "#18BFFF", about: String(localized: "Base、数据表和记录")),
        "dropbox": Look(mark: "dropbox", hex: "#0061FF", about: String(localized: "文件和文件夹")),
        "zapier": Look(mark: "zapier", hex: "#FF4F00", about: String(localized: "Zap 和应用操作")),
        "clickup": Look(mark: "clickup", hex: "#7B68EE", about: String(localized: "任务、列表和文档")),
        "todoist": Look(mark: "todoist", hex: "#E44332", about: String(localized: "任务和项目")),
        "miro": Look(mark: "miro", hex: "#050038", about: String(localized: "白板和白板上的内容")),
        "attio": Look(hex: "#1E1E24", about: String(localized: "CRM 记录、列表和备注")),
        "postman": Look(mark: "postman", hex: "#FF6C37", about: String(localized: "集合、请求和工作区")),
        "asana": Look(mark: "asana", hex: "#F06A6A", about: String(localized: "任务、项目和工作区")),
        "box": Look(mark: "box", hex: "#0061D5", about: String(localized: "文件、文件夹和元数据")),
        "hubspot": Look(mark: "hubspot", hex: "#FF7A59", about: String(localized: "联系人、交易和工单")),
        "slack": Look(hex: "#4A154B", about: String(localized: "频道和消息")),
        "huggingface": Look(mark: "huggingface", hex: "#FFD21E", about: String(localized: "模型、数据集和 Spaces")),
        "exa": Look(hex: "#2B50E8", about: String(localized: "给智能体用的网页搜索")),
        "deepwiki": Look(hex: "#0E7490", about: String(localized: "公开代码仓库的文档")),
        "context7": Look(hex: "#059669", about: String(localized: "各种库的文档和代码示例")),
        "mslearn": Look(hex: "#0078D4", about: String(localized: "微软产品文档")),
        "cloudflare-docs": Look(mark: "cloudflare", hex: "#F38020", about: String(localized: "Cloudflare 产品文档")),
        "amap": Look(hex: "#1677FF", about: String(localized: "国内的地图、地点和路线")),
    ]
}

/// A connector's tile: its mark (or initial) on its colour; one of the user's own gets a plain tile.
struct ConnectorIcon: View {
    let id: String
    var name = ""
    var size: CGFloat = 40
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            if let look = ConnectorBrand.look(id), let color = Color(hex: look.hex) {
                let light = Self.luminance(look.hex)
                // A near-black tile would vanish on a dark page: there it turns white, its mark dark.
                let flipped = scheme == .dark && light < 0.02
                let ink = flipped || light > 0.6 ? Color(white: 0.07) : Color.white
                shape.fill(flipped ? Color.white : color)
                if let mark = look.mark {
                    Image("Connectors/\(mark)").resizable().scaledToFit().frame(width: size * 0.56, height: size * 0.56).foregroundStyle(ink)
                } else {
                    Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.48, weight: .bold, design: .rounded)).foregroundStyle(ink)
                }
            } else {
                shape.fill(Palette.control)
                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: size * 0.44)).foregroundStyle(Palette.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(Palette.stroke, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    /// How light a colour is, 0…1 (relative luminance).
    private static func luminance(_ hex: String) -> Double {
        guard let value = UInt32(hex.dropFirst(), radix: 16) else { return 0 }
        let channels = [16, 8, 0].map { shift -> Double in
            let channel = Double((value >> UInt32(shift)) & 0xff) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}

// MARK: - The list

/// Services the Bots can use through MCP: signed in once, shared by the team. The ones in use
/// come first; the rest are found by kind or by name.
struct BotConnectorsPage: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false
    @State private var query = ""
    /// nil: every kind.
    @State private var category: String?

    private static let order = ["dev", "docs", "work", "design", "data", "commerce", "search", "custom"]

    var body: some View {
        let team = app.botTeam
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = team.connectors.filter { row in
            needle.isEmpty || ConnectorBrand.name(row).lowercased().contains(needle) || (row["name"].string ?? "").lowercased().contains(needle)
                || ConnectorBrand.about(row).lowercased().contains(needle)
        }
        // In use, or on the way there: the ones that need a hand first.
        let mine = rows.filter { $0["state"].string != "off" }.sorted { Self.rank($0) < Self.rank($1) }
        let kinds = Self.order.filter { kind in team.connectors.contains { Self.kind($0) == kind } }
        List {
            if needle.isEmpty, kinds.count > 1 {
                Section { pills(kinds) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if category == nil, !mine.isEmpty {
                Section(needle.isEmpty ? String(localized: "已连接") : String(localized: "已连接里找到的")) { ForEach(mine, id: \.["id"]) { link($0) } }
                    .groupedRow()
            }
            ForEach(Self.order.filter { category == nil || $0 == category }, id: \.self) { kind in
                // With every kind shown, the ones in use are above already.
                let group = rows.filter { Self.kind($0) == kind && (category != nil || $0["state"].string == "off") }
                if !group.isEmpty {
                    Section(Self.title(kind)) { ForEach(group, id: \.["id"]) { link($0) } }
                        .groupedRow()
                }
            }
            if !needle.isEmpty, rows.isEmpty {
                Section { Text("没有找到「\(query)」").font(.footnote).foregroundStyle(Palette.secondary) }
                    .groupedRow()
            }
            if needle.isEmpty, category == nil || category == "custom" {
                Section {
                    Button { adding = true } label: { Label("添加自定义连接器", systemImage: "plus") }
                } footer: {
                    Text("连接器是 MCP 服务。iOS 上只能用网址形式的连接器，需要启动本地命令的那种只能在电脑上用。")
                }
                .groupedRow()
            }
        }
        .groupedList()
        .navigationTitle("连接器")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索服务")
        .sheet(isPresented: $adding) { CustomConnectorSheet() }
        .task { await team.refreshState() }
    }

    private func link(_ row: JSON) -> some View {
        NavigationLink { BotConnectorPage(id: row["id"].string ?? "") } label: { ConnectorRow(row: row) }
    }

    /// The kinds, as capsules that scroll sideways; the picked one is filled.
    private func pills(_ kinds: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(String(localized: "全部"), picked: category == nil) { category = nil }
                ForEach(kinds, id: \.self) { kind in pill(Self.title(kind), picked: category == kind) { category = kind } }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
    }

    private func pill(_ title: String, picked: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            Text(title).font(.subheadline.weight(picked ? .semibold : .regular))
                .foregroundStyle(picked ? Palette.onInk : Palette.ink)
                .padding(.horizontal, 14).frame(height: 34)
                .background(picked ? Palette.ink : Palette.control, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private static func kind(_ row: JSON) -> String {
        let kind = row["category"].string ?? "custom"
        return order.contains(kind) ? kind : "custom"
    }

    /// What needs the user first: broken, then waiting for a sign-in, then connecting, then fine.
    private static func rank(_ row: JSON) -> Int {
        switch row["state"].string {
        case "error": 0
        case "needs-client", "needs-sign-in": 1
        case "connecting": 2
        default: 3
        }
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
        HStack(spacing: 12) {
            ConnectorIcon(id: row["id"].string ?? "", name: row["name"].string ?? "", size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(ConnectorBrand.name(row)).foregroundStyle(Palette.ink)
                let about = ConnectorBrand.about(row)
                if !about.isEmpty { Text(about).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            // One not in use says nothing: the list would be forty lines of 「未连接」.
            if row["state"].string != "off" { ConnectorState(row: row) }
        }
        .padding(.vertical, 2)
    }
}

/// Where a connector stands, in a word and its colour.
struct ConnectorState: View {
    let row: JSON

    var body: some View {
        let (symbol, text, color): (String?, String, Color) = switch row["state"].string {
        case "ready": ("checkmark.circle.fill", row["account"].string ?? String(localized: "已连接"), Palette.added)
        case "connecting": (nil, String(localized: "连接中"), Palette.running)
        case "error": ("exclamationmark.circle.fill", String(localized: "出错"), Palette.removed)
        case "needs-client", "needs-sign-in": ("person.crop.circle.badge.exclamationmark", String(localized: "需要登录"), Palette.waiting)
        default: (nil, String(localized: "未连接"), Palette.faint)
        }
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) } else if row["state"].string == "connecting" { ProgressView().controlSize(.mini) }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(color)
    }
}

// MARK: - One connector

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
            Section { header(row, state: state) }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

            if state == "ready" || state == "connecting" && row["pending"].isNull {
                connected(row)
            } else if let pending = row["pending"].nonNull {
                signingIn(pending)
            } else if state == "needs-client" {
                Section {
                    TextField("Client ID", text: $clientId).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Client Secret（可不填）", text: $clientSecret)
                } footer: { Text("这个服务需要你自己的 OAuth 应用。在服务的开发者后台创建后，把 Client ID 填在这里。") }
                .groupedRow()
                action("继续登录", disabled: clientId.isEmpty) { run("connector-client", ["id": .string(id), "clientId": .string(clientId), "clientSecret": .string(clientSecret)]) }
            } else {
                switch kind {
                case "none":
                    action("连接", footer: "不需要登录，连上就能用。") { run("connector-connect", ["id": .string(id)]) }
                case "key":
                    Section {
                        SecureField("API Key", text: $key)
                        if let url = row["auth"]["keyUrl"].string.flatMap(URL.init(string:)) { Link("去申请 Key", destination: url) }
                    }
                    .groupedRow()
                    action("保存并连接", disabled: key.isEmpty) { run("connector-connect", ["id": .string(id), "key": .string(key)]) }
                default:
                    action(id == "github" ? "用 GitHub 账号登录" : "登录并连接", footer: "会在 App 里打开登录页面，登录完回到这里。") { run("connector-connect", ["id": .string(id)]) }
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
        .navigationTitle(ConnectorBrand.name(row))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: row["pending"]["url"].string) { _, url in
            // A browser sign-in: the page runs inside the app so the engine, which listens for
            // the redirect, keeps running.
            if let url = url.flatMap(URL.init(string:)) { InAppSafari.open(url) }
        }
    }

    /// The service's face, what it gives a Bot, and where the connection stands.
    private func header(_ row: JSON, state: String) -> some View {
        VStack(spacing: 8) {
            ConnectorIcon(id: id, name: row["name"].string ?? id, size: 76)
            Text(ConnectorBrand.name(row)).font(.title3.weight(.semibold)).padding(.top, 4)
            let about = ConnectorBrand.about(row)
            if !about.isEmpty { Text(about).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            ConnectorState(row: row)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            if let error = row["error"].string, state == "error" {
                Text(BotErrorText.text(error)).font(.footnote).foregroundStyle(Palette.removed).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// The one thing to do on the page, as the page's one filled button.
    private func action(_ title: LocalizedStringKey, footer: LocalizedStringKey? = nil, disabled: Bool = false, run: @escaping () -> Void) -> some View {
        Section {
            Button { Haptics.tap(); run() } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(Palette.onInk) }
                    Text(title)
                }
            }
            .buttonStyle(.capsule(height: 50))
            .disabled(disabled || busy)
        } footer: {
            if let footer { Text(footer).frame(maxWidth: .infinity).multilineTextAlignment(.center) }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder
    private func connected(_ row: JSON) -> some View {
        let team = app.botTeam
        let off = Set(row["offFor"].array.compactMap(\.string))
        if row["account"].string != nil || (row["tools"].int ?? 0) > 0 {
            Section {
                if let account = row["account"].string { LabeledContent("账号", value: account) }
                if let tools = row["tools"].int, tools > 0 { LabeledContent("可用工具", value: String(localized: "\(tools) 个")) }
            }
            .groupedRow()
        }
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

