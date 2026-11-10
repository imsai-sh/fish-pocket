import CoreImage.CIFilterBuiltins
import SwiftUI

/// Chat apps a Bot can be reached from (ds-bot's IM bridge). The bridge runs inside the
/// engine, so messages arrive only while the app is running.
struct BotIMPage: View {
    @Environment(AppModel.self) private var app
    @State private var adding: IMPlatform?

    var body: some View {
        let team = app.botTeam
        let connections = team.team["im"]["connections"].array
        List {
            if !connections.isEmpty {
                Section {
                    ForEach(connections, id: \.["id"]) { connection in
                        NavigationLink { IMConnectionPage(id: connection["id"].string ?? "") } label: { IMConnectionRow(connection: connection) }
                    }
                } header: { Text("已连接") }
                .groupedRow()
            }
            Section {
                // The platforms this engine can connect to (`im.platforms`), in the plugin's order.
                let offered = team.team["im"]["platforms"].array.compactMap(\.string)
                ForEach(IMPlatform.all.filter { offered.isEmpty || offered.contains($0.id) }) { platform in
                    Button { adding = platform } label: {
                        HStack {
                            Text(platform.name).foregroundStyle(Palette.ink)
                            Spacer()
                            Image(systemName: "plus").foregroundStyle(Palette.secondary)
                        }
                    }
                }
            } header: {
                Text("添加")
            } footer: {
                Text("连上以后，在这些聊天软件里给机器人发消息，就会交给你选的 Bot。消息只在 Fish Pocket 运行时收得到。")
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle("聊天软件")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $adding) { platform in IMAddSheet(platform: platform) }
        .task { await team.refreshState() }
    }
}

/// ds-bot's IM platforms (shared/im-platforms.js): how each one is added.
struct IMPlatform: Identifiable, Hashable {
    struct Field: Hashable {
        let key: String
        let label: String
        var secret = false
        var options: [(String, String)] = []
        static func == (a: Field, b: Field) -> Bool { a.key == b.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    let id: String
    let name: String
    var fields: [Field] = []
    var qr = false
    var help: String?

    static let all: [IMPlatform] = [
        IMPlatform(id: "weixin", name: String(localized: "微信"), qr: true),
        IMPlatform(id: "feishu", name: String(localized: "飞书 / Lark"), fields: [
            Field(key: "domain", label: String(localized: "版本"), options: [("feishu", String(localized: "飞书")), ("lark", "Lark")]),
            Field(key: "appId", label: "App ID"), Field(key: "appSecret", label: "App Secret", secret: true),
        ]),
        IMPlatform(id: "dingtalk", name: String(localized: "钉钉"), fields: [Field(key: "clientId", label: "Client ID"), Field(key: "clientSecret", label: "Client Secret", secret: true)]),
        IMPlatform(id: "wecom", name: String(localized: "企业微信"), fields: [Field(key: "botId", label: "Bot ID"), Field(key: "secret", label: "Secret", secret: true)]),
        IMPlatform(id: "qq", name: "QQ", fields: [Field(key: "appId", label: "App ID"), Field(key: "appSecret", label: "App Secret", secret: true)]),
        IMPlatform(id: "telegram", name: "Telegram", fields: [Field(key: "token", label: "Bot token", secret: true)], help: "https://t.me/BotFather"),
        IMPlatform(id: "discord", name: "Discord", fields: [Field(key: "token", label: "Bot token", secret: true)]),
        IMPlatform(id: "slack", name: "Slack", fields: [Field(key: "appToken", label: "App-Level Token (xapp-)", secret: true), Field(key: "botToken", label: "Bot Token (xoxb-)", secret: true)]),
    ]

    static func name(_ id: String?) -> String { all.first { $0.id == id }?.name ?? id ?? "" }
}

private struct IMConnectionRow: View {
    @Environment(AppModel.self) private var app
    let connection: JSON

    var body: some View {
        let team = app.botTeam
        let status = team.live["imStatus"]?[connection["id"].string ?? ""]
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(IMPlatform.name(connection["platform"].string)).foregroundStyle(Palette.ink)
                let target = connection["botId"].string.flatMap(team.bot).map { String(localized: "交给\($0.name)") }
                Text([connection["account"]["name"].string ?? connection["account"].string, target].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Text(IMConnectionPage.stateText(status, enabled: connection["enabled"].bool ?? true)).font(.caption).foregroundStyle(Palette.secondary)
        }
    }
}

/// One connection: which Bot answers, who may talk to it, and its chats.
private struct IMConnectionPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: String

    var body: some View {
        let team = app.botTeam
        let connection = team.team["im"]["connections"].array.first { $0["id"].string == id } ?? .null
        let status = team.live["imStatus"]?[id]
        List {
            Section {
                LabeledContent("状态", value: Self.stateText(status, enabled: connection["enabled"].bool ?? true))
                if let error = status?["error"].string { Text(BotErrorText.text(error)).font(.footnote).foregroundStyle(Palette.removed) }
                Picker("交给", selection: Binding(get: { connection["botId"].string ?? "" }, set: { botId in
                    Task { await team.run("im-update", ["id": .string(id), "botId": .string(botId)]) }
                })) {
                    ForEach(team.bots) { Text($0.name).tag($0.id) }
                }
                Toggle("开启", isOn: Binding(get: { connection["enabled"].bool ?? true }, set: { on in
                    Task { await team.run("im-update", ["id": .string(id), "enabled": .bool(on)]) }
                }))
                if status?["state"].string == "error" { Button("重试") { Task { await team.run("im-retry", ["id": .string(id)]) } } }
            }
            .groupedRow()
            let requests = connection["requests"].array
            if !requests.isEmpty {
                Section {
                    ForEach(requests, id: \.["id"]) { request in
                        HStack {
                            Text(request["name"].string ?? request["id"].string ?? "")
                            Spacer()
                            Button("允许") { Task { await team.run("im-pair", ["id": .string(id), "senderId": request["id"], "allow": true]) } }
                                .buttonStyle(.borderless)
                            Button("拒绝") { Task { await team.run("im-pair", ["id": .string(id), "senderId": request["id"], "allow": false]) } }
                                .buttonStyle(.borderless).foregroundStyle(Palette.removed)
                        }
                    }
                } header: { Text("想和 Bot 聊天的人") } footer: { Text("第一次发消息的人要你允许后，Bot 才会回复。") }
                .groupedRow()
            }
            let paired = connection["paired"].array
            if !paired.isEmpty {
                Section("已允许") {
                    ForEach(paired, id: \.["id"]) { person in
                        Text(person["name"].string ?? person["id"].string ?? "")
                            .swipeActions {
                                Button("移除", role: .destructive) { Task { await team.run("im-unpair", ["id": .string(id), "senderId": person["id"]]) } }
                            }
                    }
                }
                .groupedRow()
            }
            let chats = connection["chats"].object.sorted { ($0.value["at"].double ?? 0) > ($1.value["at"].double ?? 0) }
            if !chats.isEmpty {
                Section {
                    ForEach(chats, id: \.key) { key, chat in
                        let target = chat["target"]["botId"].string.map { "b:\($0)" } ?? chat["target"]["roomId"].string.map { "r:\($0)" } ?? ""
                        Picker(selection: Binding(get: { target }, set: { next in
                            let value: JSON = next.hasPrefix("b:") ? ["botId": .string(String(next.dropFirst(2)))] : next.hasPrefix("r:") ? ["roomId": .string(String(next.dropFirst(2)))] : .null
                            Task { await team.run("im-chat", ["id": .string(id), "chatKey": .string(key), "target": value]) }
                        })) {
                            Text("跟着这个连接").tag("")
                            Section("Bot") { ForEach(team.bots) { Text($0.name).tag("b:\($0.id)") } }
                            if !team.rooms.isEmpty { Section("群聊") { ForEach(team.rooms) { Text(team.name(of: $0)).tag("r:\($0.id)") } } }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chat["title"].string ?? key)
                                Text(chat["kind"].string == "group" ? String(localized: "群") : String(localized: "私聊")).font(.caption).foregroundStyle(Palette.secondary)
                            }
                        }
                        .swipeActions {
                            Button("移除", role: .destructive) { Task { await team.run("im-chat", ["id": .string(id), "chatKey": .string(key), "remove": true]) } }
                        }
                    }
                } header: { Text("聊过的会话") } footer: { Text("每个会话可以单独交给某个 Bot 或某个群聊。左滑移除记录。") }
                .groupedRow()
            }
            Section {
                Button("断开并移除", role: .destructive) {
                    Task { if await team.run("im-remove", ["id": .string(id)]) { dismiss() } }
                }
            }
            .groupedRow()
        }
        .groupedList()
        .navigationTitle(IMPlatform.name(connection["platform"].string))
        .navigationBarTitleDisplayMode(.inline)
    }

    static func stateText(_ status: JSON?, enabled: Bool) -> String {
        guard enabled else { return String(localized: "已关闭") }
        switch status?["state"].string {
        case "connected", "ready", "online": return String(localized: "已连接")
        case "connecting": return String(localized: "连接中")
        case "error": return String(localized: "出错")
        case "off": return String(localized: "已断开")
        default: return String(localized: "等待连接")
        }
    }
}

/// Add a connection: fill the platform's fields, or scan a code for WeChat.
private struct IMAddSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let platform: IMPlatform
    @State private var botId = ""
    @State private var values: [String: String] = [:]
    @State private var saving = false
    @State private var login: JSON = .null
    @State private var loginState = ""

    var body: some View {
        let team = app.botTeam
        NavigationStack {
            Form {
                Section {
                    Picker("交给", selection: $botId) {
                        ForEach(team.bots) { Text($0.name).tag($0.id) }
                    }
                } footer: { Text("在\(platform.name)里收到的消息交给这个 Bot 回复。") }
                if platform.qr {
                    Section {
                        if let code = login["qr"].string, let image = Self.qr(code) {
                            VStack(spacing: 10) {
                                Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
                                Text(loginState).font(.footnote).foregroundStyle(Palette.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Button(saving ? "正在获取二维码…" : "获取登录二维码") { Task { await startLogin() } }.disabled(saving || botId.isEmpty)
                        }
                    } footer: { Text("用另一台手机上的微信扫码，确认后这个微信号就成了 Bot 的入口。") }
                } else {
                    Section {
                        ForEach(platform.fields, id: \.key) { field in
                            if !field.options.isEmpty {
                                Picker(field.label, selection: Binding(get: { values[field.key] ?? field.options[0].0 }, set: { values[field.key] = $0 })) {
                                    ForEach(field.options, id: \.0) { Text($0.1).tag($0.0) }
                                }
                            } else if field.secret {
                                SecureField(field.label, text: Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 }))
                            } else {
                                TextField(field.label, text: Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 }))
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                        }
                        if let help = platform.help.flatMap(URL.init(string:)) { Link("去创建机器人", destination: help) }
                    } footer: { Text("在\(platform.name)的开放平台创建一个机器人应用，把凭据填在这里。密钥只存在这台设备上。") }
                }
            }
            .navigationTitle(platform.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                if !platform.qr {
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() } else {
                            Button("连接") { Task { await add() } }
                                .disabled(botId.isEmpty || platform.fields.contains { $0.options.isEmpty && (values[$0.key] ?? "").isEmpty })
                        }
                    }
                }
            }
            .onAppear { if botId.isEmpty { botId = team.mainBot?.id ?? "" } }
        }
    }

    private func add() async {
        saving = true
        defer { saving = false }
        var fields: [String: JSON] = [:]
        for field in platform.fields { fields[field.key] = .string(values[field.key] ?? field.options.first?.0 ?? "") }
        if await app.botTeam.run("im-add", ["platform": .string(platform.id), "botId": .string(botId), "fields": .object(fields)]) { dismiss() }
    }

    /// WeChat: a code to scan, then long polls until it is scanned and confirmed.
    private func startLogin() async {
        saving = true
        defer { saving = false }
        do {
            login = try await app.botTeam.call("im-login-start", ["platform": .string(platform.id), "botId": .string(botId)])
            loginState = String(localized: "等待扫码…")
            while !Task.isCancelled, let loginId = login["loginId"].string {
                let answer = try await app.botTeam.call("im-login-wait", ["platform": .string(platform.id), "botId": .string(botId), "loginId": .string(loginId)])
                switch answer["status"].string {
                case "scanned": loginState = String(localized: "已扫码，请在手机上确认")
                case "expired": loginState = String(localized: "二维码过期了"); login = .null; return
                case "done": await app.botTeam.refreshState(); dismiss(); return
                default: break
                }
            }
        } catch {
            app.showToast(BotErrorText.text(error.localizedDescription), tone: .warning)
        }
    }

    static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
