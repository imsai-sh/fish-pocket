import SafariServices
import SwiftUI
import WatchConnectivity

/// Settings: only what people come here for (账号, 模型, 访问模式, 插件, 自动化, 后台运行: 静音音频,
/// 任务续跑, 小组件), then the rarely touched 外观, App 图标 and 语言. Developer pages sit behind 高级, versions and
/// engine status behind 关于, and 已归档会话 on its own below them. 本机能力 (under 连接器) and 远程控制 are on the 探索 tab (in the sidebar on an iPad before iOS 18), not here.
/// 分享 Fish Pocket and Apple Watch open the list and the rating, website, feedback and community
/// links close it (`SupportLink`) only on an iPad before iOS 18: elsewhere they are on the 探索 tab.
/// The engine card shows here only while the engine is not running. Every page reads the shared
/// settings mirror, so a write anywhere shows everywhere.
struct SettingsView: View {
    /// A page of the 探索 tab, pushed from its top row, rather than a sheet: that tab's navigation
    /// stack and back button, no ✕. The stack sets the settings look for it (`ExploreTabView`).
    var pushed = false

    var body: some View {
        if pushed { SettingsList(pushed: true) } else { SettingsSheet() }
    }
}

extension SettingsView {
    /// A permission preset in the words the app uses everywhere (`{value, name}`).
    static func permissionName(_ option: JSON) -> String {
        switch option["value"].string {
        case "read-only": String(localized: "仅可查看")
        case "workspace-write": String(localized: "工作区内修改")
        case "danger-full-access": String(localized: "完全权限")
        case "auto": String(localized: "自动审查")
        default: localized(option["name"]) ?? option["value"].string ?? ""
        }
    }
}

/// 设置 as a sheet, with its ✕. `dismiss` is read here, outside the stack, and not by the list:
/// the list pushes further, and a pushed page that reads it and pushes on freezes the app before
/// iOS 26 (see `dismisses(when:)`). Pushed from the 探索 tab the list is such a page: there
/// 插件 and 自动化 never opened and the app had to be killed.
private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack { SettingsList(pushed: false).closeButton(dismiss) }
            // 设置 and every page pushed or presented from it: the system's lists, not the monochrome ones.
            .settingsStyle()
    }
}

private struct SettingsList: View {
    @Environment(AppModel.self) private var app
    @EnvironmentObject private var engine: NodeEngine
    @Environment(\.openSession) private var openSession
    @State private var defaultModel: String?
    @State private var pluginCount: Int?
    @State private var engineVersion: String?
    @State private var permissionOptions: [JSON] = []
    /// What new sessions start with until the user picks: the setting's value is empty then.
    @State private var catalogDefaultPermission = ""
    @State private var confirmingFullAccess = false
    @AppStorage(BackgroundKeeper.enabledKey) private var keepAlive = true
    @State private var confirmingKeepAliveOff = false
    @State private var languageChoice = AppLanguage.chosen ?? "system"
    @State private var languageChanged = false
    @AppStorage(BackgroundKeeper.continuedKey) private var continuedProcessing = false
    @AppStorage(WidgetSnapshotWriter.showTitlesKey) private var widgetTitles = true
    /// Pushed from the 探索 tab rather than the root of the sheet (`SettingsView.pushed`).
    let pushed: Bool

    private var mirror: SettingsMirror { app.settings }

    private var engineRunning: Bool {
        if case .running = engine.phase { return true }
        return false
    }

    var body: some View {
        List {
            if !engineRunning {
                Section { EngineCard() }
            }

            // Pushed from the 探索 tab, these two are on that page.
            if !pushed {
                Section {
                    NavigationLink { ShareAppPage() } label: { ShareAppRow() }
                    // iPad pairs with no watch.
                    if WCSession.isSupported() {
                        NavigationLink { WatchSetupPage() } label: { WatchSetupRow() }
                    }
                }
            }

            // The ways to reach a model, each on its own: Fish Pocket credits (when this build
            // has the service), the DeepSeek account, an API key.
            Section {
                if app.fishPocket.available {
                    NavigationLink { FishPocketPage() } label: {
                        row("Fish Pocket 账号", "sparkles", app.fishPocket.signedIn
                            ? (app.fishPocket.balance.map { String(localized: "\($0) 积分") } ?? String(localized: "已登录"))
                            : String(localized: "未登录"))
                    }
                }
                NavigationLink { AccountPage() } label: {
                    row("DeepSeek 账号", "person.crop.circle", app.account.signedIn ? (app.account.displayName ?? String(localized: "已登录")) : String(localized: "未登录"))
                }
                DeepSeekKeyRow()
            } header: {
                Text("连接方式")
            } footer: {
                Text("几种方式相互独立，配置任意一种就能开始对话。")
            }

            Section {
                NavigationLink { ModelProvidersPage() } label: { row("模型", "cpu", defaultModel ?? "") }
                NavigationLink { VoiceInputSettingsPage() } label: {
                    row("语音输入", "mic", VoicePreferences.shared.source == .volcengine && !VolcSpeech.shared.configured ? String(localized: "未设置") : VoicePreferences.shared.source.title)
                }
                NavigationLink { ReadAloudSettingsPage() } label: {
                    row("朗读", "speaker.wave.2", readingSummary)
                }
                NavigationLink { VoiceCallSettingsPage() } label: {
                    row("语音通话", "waveform", VolcSpeech.shared.configured ? CallVoice.chosen.name : String(localized: "未设置"))
                }
                NavigationLink { VoiceMessageSettingsPage() } label: {
                    row("语音消息", "message.badge.waveform", VoiceMessageSettings.shared.summary)
                }
                // dsh-image-gen, built into the engine: shown once the engine serves its settings.
                if mirror.serves(ImageGenModel.namespace) {
                    NavigationLink { ImageGenSettingsPage() } label: {
                        let value = mirror.namespace(ImageGenModel.namespace)?["value"] ?? .null
                        row("生图", "photo.badge.plus", FishPocketImageGen.isChosen(value) ? FishPocketImageGen.title : (ImageGenProvider(rawValue: value["provider"].string ?? "") ?? .google).title)
                    }
                }
                if mirror.serves("permission") { permissionPicker }
            }

            Section {
                NavigationLink { PluginsView() } label: {
                    row("插件", "puzzlepiece.extension", pluginCount.map { String(localized: "\($0) 个") } ?? "")
                }
                NavigationLink { SchedulesView(openSession: openSession.map { open in { open($0) } }) } label: {
                    row("自动化", "clock.arrow.2.circlepath", app.scheduleCount.map { String(localized: "\($0) 个") } ?? "")
                }
            }

            Section {
                // Turning it off asks first: without it the system may end the engine in the background.
                Toggle(isOn: Binding(get: { keepAlive }, set: { on in
                    if on { keepAlive = true } else { confirmingKeepAliveOff = true }
                })) {
                    Label("静音音频", systemImage: "speaker.slash")
                }
                // The system's continued-processing task exists from iOS 26 only.
                if #available(iOS 26.0, *) {
                    Toggle(isOn: $continuedProcessing) { Label("任务续跑", systemImage: "hourglass") }
                }
            } header: {
                Text("后台运行")
            } footer: {
                Text(backgroundFooter)
            }
            .onChange(of: keepAlive) { BackgroundKeeper.shared.settingsChanged() }
            .onChange(of: continuedProcessing) { BackgroundKeeper.shared.settingsChanged() }
            .alert("关闭静音音频？", isPresented: $confirmingKeepAliveOff) {
                Button("取消", role: .cancel) {}
                Button("关闭", role: .destructive) { keepAlive = false }
            } message: {
                Text("离开 App 时\(turnsOffScreen)，之后引擎可能被系统暂停，自动化和开发服务器会中断。")
            }

            Section {
                Toggle(isOn: $widgetTitles) { Label("显示会话标题", systemImage: "eye") }
            } header: {
                Text("小组件")
            } footer: {
                Text("关掉后，主屏幕和锁屏小组件只显示数量和状态。设备锁定时，标题总会被打码。")
            }
            .onChange(of: widgetTitles) { WidgetSnapshotWriter.shared.refresh() }

            Section {
                if let theme = mirror.namespace("ui-theme") {
                    Picker(selection: Binding(get: { theme["value"]["preference"].string ?? "system" }, set: { value in
                        Task { await write("ui-theme", ["preference"], .string(value)) }
                    })) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    } label: {
                        Label("外观", systemImage: "circle.lefthalf.filled")
                    }
                    .pickerValueTint()
                }
                if AppIconChoice.available {
                    NavigationLink { AppIconPage() } label: { AppIconRow() }
                }
                // iOS shows the per-app language in its Settings only to readers with several system
                // languages; this picker writes the same preference, applied at the next launch.
                Picker(selection: $languageChoice) {
                    Text("跟随系统").tag("system")
                    ForEach(AppLanguage.choices, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                } label: {
                    Label("语言", systemImage: "globe")
                }
                .pickerValueTint()
                .onChange(of: languageChoice) { _, value in
                    AppLanguage.chosen = value == "system" ? nil : value
                    languageChanged = true
                }
            }

            Section {
                NavigationLink { AdvancedSettingsPage() } label: { row("高级", "wrench.and.screwdriver") }
                NavigationLink { AboutPage(engineVersion: engineVersion) } label: { row("关于", "info.circle", aboutValue) }
            }

            // Out of the sessions list: a tap there is to open a conversation, and an archived one does not open.
            Section {
                NavigationLink { DrawerView.archive() } label: {
                    let count = DrawerView.archivedCount(app)
                    row("已归档会话", "archivebox", count > 0 ? "\(count)" : "")
                }
            }

            // On the 探索 tab when there is one; an iPad before iOS 18 has 设置 as a sheet and no such tab.
            if !pushed { SupportLinksSection() }

        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(pushed ? .inline : .large)
        .alert("重启 App 后生效", isPresented: $languageChanged) {
            Button("好", role: .cancel) {}
        } message: {
            Text("退出 Fish Pocket 再重新打开，界面就会换成新的语言。")
        }
        .alert("启用完全权限？", isPresented: $confirmingFullAccess) {
            Button("取消", role: .cancel) {}
            Button("启用", role: .destructive) { Task { await write("permission", ["defaultPreset"], "danger-full-access") } }
        } message: {
            Text("新会话将减少确认步骤，可以直接改文件、跑命令。仅在信任后续任务时使用。")
        }
        .followSettings()
        .task { await load() }
        .task(id: app.settingsRevision) { await loadDerived() }
        .task(id: app.revision("permission-presets/catalog-changed")) { await loadPermissions() }
    }

    /// 朗读's value: the voice, Volcengine's being the call's, or 未设置 until it can be reached.
    private var readingSummary: String {
        switch VoicePreferences.shared.readingSource {
        case .deepseek: VoicePreferences.shared.readingVoice.title
        case .volcengine: VolcSpeech.shared.configured ? CallVoice.chosen.name : String(localized: "未设置")
        }
    }

    private var aboutValue: String {
        if case .available = UpdateChecker.shared.status { return String(localized: "有新版本") }
        return ""
    }

    private func row(_ title: LocalizedStringKey, _ icon: String, _ value: String = "") -> some View {
        LabeledContent {
            Text(value).lineLimit(1)
        } label: {
            Label(title, systemImage: icon)
        }
    }

    /// G-01: the permission new sessions start with; full access asks first.
    private var permissionPicker: some View {
        let current = mirror.namespace("permission")?["value"]["defaultPreset"].string ?? catalogDefaultPermission
        return Picker(selection: Binding(get: { current }, set: { value in
            if value == "danger-full-access" { confirmingFullAccess = true }
            else { Task { await write("permission", ["defaultPreset"], .string(value)) } }
        })) {
            ForEach(permissionOptions, id: \.self) { option in
                Text(SettingsView.permissionName(option)).tag(option["value"].string ?? "")
            }
            if !permissionOptions.contains(where: { $0["value"].string == current }) {
                Text(current).tag(current)
            }
        } label: {
            Label("默认访问模式", systemImage: "lock.shield")
        }
        .pickerValueTint()
    }

    /// 任务续跑 is on and available (BackgroundKeeper's continued task needs iOS 26).
    private var continuesTurns: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return continuedProcessing
    }

    /// What happens to in-flight turns without silent audio.
    private var turnsOffScreen: String {
        continuesTurns
            ? String(localized: "进行中的任务会继续跑完（系统显示进度，可随时停止）")
            : String(localized: "进行中的任务最多再跑约 30 秒")
    }

    private var backgroundFooter: String {
        guard keepAlive else { return String(localized: "离开 App 后，\(turnsOffScreen)，之后引擎可能被系统暂停。") }
        return continuesTurns
            ? String(localized: "离开 App 后播放无声音频，任务、自动化和开发服务器都不停，会多耗一些电。音频被来电等打断时，进行中的任务仍会继续跑完。")
            : String(localized: "离开 App 后播放无声音频，任务、自动化和开发服务器都不停。会多耗一些电。")
    }

    private func load() async {
        if let value = try? await app.client.call("pluginManager/listBundles") {
            let bundles = value.array
            pluginCount = bundles.filter { $0["enabled"].bool == true && !PluginManagerModel.builtInProfileBundles.contains($0["name"].string ?? "") }.count
            engineVersion = bundles.first { $0["name"].string == "@deepseek-ai/dsh-base" }?["version"].string
        }
        await app.account.refresh()
    }

    /// What the rows show that depends on settings.
    private func loadDerived() async {
        if let value = try? await app.client.call("session/modelCatalog") {
            let provider = value["default"]["provider"].string, model = value["default"]["model"].string
            let group = value["groups"].array.first { $0["id"].string == provider }
            defaultModel = group?["models"].array.first { $0["id"].string == model }?["name"].string ?? model
        }
    }

    private func loadPermissions() async {
        if let value = try? await app.client.call("permissionPresets/catalog") {
            permissionOptions = value["defaultOptions"].array.isEmpty ? value["options"].array : value["defaultOptions"].array
            catalogDefaultPermission = value["defaultPreset"].string ?? ""
        }
    }

    private func write(_ ns: String, _ path: [String], _ value: JSON) async {
        do {
            try await mirror.set(ns, path, value)
            if ns == "ui-theme" { await app.reloadTheme() }
        } catch {
            Haptics.error()
            app.showToast(describeFailure(error), duration: 5)
        }
    }
}

/// 设置 → 高级: the pages for people who look under the hood.
private struct AdvancedSettingsPage: View {
    @Environment(AppModel.self) private var app
    @EnvironmentObject private var engine: NodeEngine
    @State private var showWeb = false
    @State private var showCordis = false

    var body: some View {
        List {
            Section {
                NavigationLink("内置插件") { PluginInventoryPage() }
                if !app.cordis.rows.isEmpty {
                    Button("Cordis 插件") { showCordis = true }
                }
                NavigationLink("Agent 预设") { AgentPresetsPage() }
                NavigationLink("全部设置") { AllSettingsPage() }
            }

            Section {
                if app.settings.hasDocument {
                    NavigationLink("配置文件") { ConfigDocumentView() }
                }
                NavigationLink("引擎日志") { EngineLogView(file: engine.logFile) }
                Button("网页版") { showWeb = true }
            } footer: {
                Text("网页版用于只有网页界面的插件，设置与这里共用同一份配置。")
            }
        }
        .sheet(isPresented: $showCordis) { CordisPanelView(currentSession: nil) }
        .navigationTitle("高级")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showWeb) { WebFallbackView() }
    }
}

/// 设置 → 关于: the way to a newer version, or a manual check for one.
private struct UpdateRow: View {
    @Environment(\.openURL) private var openURL
    private let checker = UpdateChecker.shared

    var body: some View {
        switch checker.status {
        case .available(let update):
            Button("更新到 \(update.version)") { openURL(update.url) }
        case .checking:
            LabeledContent("检查更新") { ProgressView() }
        case .idle, .upToDate, .failed:
            Button { Task { await checker.check() } } label: {
                LabeledContent("检查更新", value: note)
            }
        }
    }

    private var note: String {
        switch checker.status {
        case .upToDate: String(localized: "已是最新版本")
        case .failed: String(localized: "检查失败")
        default: ""
        }
    }
}

/// 设置 → 关于: versions, storage and how the engine is doing.
private struct AboutPage: View {
    @Environment(AppModel.self) private var app
    @EnvironmentObject private var engine: NodeEngine
    let engineVersion: String?
    @State private var storage: Int64?

    var body: some View {
        List {
            Section { EngineCard() }
            Section {
                LabeledContent("引擎", value: "DeepSeek Harness")
                if let engineVersion { LabeledContent("引擎版本", value: engineVersion) }
                if let bot = app.botTeam.installedPackage {
                    Link(destination: BotModel.projectURL) {
                        LabeledContent("Bot 插件", value: "DS Bot \(bot.version ?? "")")
                    }
                    .foregroundStyle(Palette.ink)
                }
                LabeledContent("App 版本", value: Self.appVersion)
                if let release = WhatsNew.current {
                    NavigationLink("新功能") { WhatsNewPage(release: release) }
                }
                UpdateRow()
                LabeledContent("系统", value: ProcessInfo.processInfo.operatingSystemVersionString)
            } footer: {
                if app.botTeam.installedPackage != nil {
                    Text("Bot 功能的后台是开源项目 DS Bot（Apache-2.0），感谢 Fei2411 和社区贡献者。")
                }
            }
            Section {
                LabeledContent("连接状态", value: app.connected ? String(localized: "已连接") : String(localized: "重新连接中"))
                LabeledContent("存储", value: storage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .task { storage = await Self.storageSize() }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    /// The engine's data and its workspaces.
    nonisolated private static func storageSize() async -> Int64 {
        await Task.detached(priority: .utility) {
            var total: Int64 = 0
            guard let walker = FileManager.default.enumerator(at: EnginePaths.data, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
            while let url = walker.nextObject() as? URL {
                total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
            return total
        }.value
    }
}

/// 全部设置: every settings namespace, by topic.
private struct AllSettingsPage: View {
    @Environment(AppModel.self) private var app

    private var mirror: SettingsMirror { app.settings }

    var body: some View {
        List {
            Section {
                ForEach(grouped, id: \.title) { group in
                    NavigationLink(group.title) {
                        List {
                            Section {
                                ForEach(group.items, id: \.self) { ns in
                                    let name = ns["ns"].string ?? ""
                                    let title = namespaceTitle(name, app)
                                    NavigationLink(title) { NamespaceFormView(title: title, ns: name) }
                                }
                            }
                        }
                        .navigationTitle(group.title)
                    }
                }
            } footer: {
                Text("这些设置和网页版、桌面版共用同一份配置。")
            }
        }
        .navigationTitle("全部设置")
        .navigationBarTitleDisplayMode(.inline)
        // The plugin titles the rows of unnamed namespaces fall back to.
        .task(id: app.revision("plugin-manager/changed")) { await app.plugins.refresh(revision: app.revision("plugin-manager/changed")) }
    }

    private var grouped: [(title: String, items: [JSON])] {
        let groups: [(String, (String) -> Bool)] = [
            (String(localized: "通用"), { ["ui-settings-general", "locale", "ui-theme", "ui-conversation", "ui-chat", "permission", "ui-settings", "ui-settings-account"].contains($0) }),
            (String(localized: "模型"), { $0.hasPrefix("llm-") || $0.contains("model") }),
            (String(localized: "智能体与工具"), { ["agent-loop", "subagent", "bash-sandbox", "web", "agent-preset-registry", "session-log-deepseek"].contains($0) || $0.hasPrefix("web-") }),
        ]
        var used = Set<String>()
        var result: [(String, [JSON])] = []
        for (title, match) in groups {
            let items = mirror.namespaces.filter { match($0["ns"].string ?? "") && !used.contains($0["ns"].string ?? "") }
            items.forEach { used.insert($0["ns"].string ?? "") }
            if !items.isEmpty { result.append((title, items)) }
        }
        let rest = mirror.namespaces.filter { !used.contains($0["ns"].string ?? "") }
        if !rest.isEmpty { result.append((String(localized: "插件"), rest)) }
        return result
    }
}

/// What a settings namespace reads as: its known name, the plugin that owns it, its schema's
/// short description, and last its key humanized; the raw namespace never shows.
@MainActor
func namespaceTitle(_ ns: String, _ app: AppModel) -> String {
    let names = [
        "ui-settings-general": String(localized: "通用"), "ui-settings": String(localized: "代码工具"), "ui-settings-account": String(localized: "账号"),
        "locale": String(localized: "语言"), "ui-theme": String(localized: "外观"), "ui-conversation": String(localized: "对话"), "ui-chat": String(localized: "输入框"),
        "permission": String(localized: "权限"), "agent-default-model": String(localized: "默认模型"), "agent-loop": String(localized: "Agent 循环"),
        "subagent": String(localized: "子智能体"), "subagent-model-selection-settings": String(localized: "子智能体模型"),
        "bash-sandbox": String(localized: "终端"), "web": String(localized: "网页工具"), "agent-preset-registry": String(localized: "Agent 预设"),
        "llm-deepseek": String(localized: "DeepSeek API"), "llm-deepseek-account": String(localized: "DeepSeek 账号模型"), "llm-pi-ai": String(localized: "其他模型服务"),
        "web-search-deepseek": String(localized: "DeepSeek 搜索"), "web-deepseek-api": String(localized: "DeepSeek 搜索 API"),
    ]
    if let name = names[ns] { return name }
    let owner = app.plugins.packages.first { package in
        package.name == ns || package.name.components(separatedBy: "/").last == ns || package.rows.contains { $0.entryId == ns || $0.rowId == ns }
    }
    if let owner { return owner.title }
    if let root = app.settings.graph(ns)?.root, let text = schemaText(root.meta["description"]), text.count <= 20, !text.contains("\n") { return text }
    return humanize(ns.replacingOccurrences(of: #"^(dsh-|ui-settings-|ui-)"#, with: "", options: .regularExpression))
}

/// Web pages in an in-app Safari, presented from UIKit over whatever is on
/// screen. Not a SwiftUI sheet: Safari's Done dismisses the controller itself,
/// and a sheet binding reset after that dismisses the sheet underneath instead.
@MainActor
enum InAppSafari {
    private final class Delegate: NSObject, SFSafariViewControllerDelegate {
        let onFinish: (() -> Void)?
        init(onFinish: (() -> Void)?) { self.onFinish = onFinish }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            MainActor.assumeIsolated {
                InAppSafari.delegates[ObjectIdentifier(controller)] = nil
                onFinish?()
            }
        }
    }

    /// The controller's delegate is weak; keep each one until its page closes.
    private static var delegates: [ObjectIdentifier: Delegate] = [:]

    /// Open `url`; `onFinish` runs when the user closes it with Done.
    @discardableResult
    static func open(_ url: URL, onFinish: (() -> Void)? = nil) -> SFSafariViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let controller = SFSafariViewController(url: url)
        // A card, as a SwiftUI sheet would be: what is under it stays on screen.
        controller.modalPresentationStyle = .pageSheet
        let delegate = Delegate(onFinish: onFinish)
        delegates[ObjectIdentifier(controller)] = delegate
        controller.delegate = delegate
        top.present(controller, animated: true)
        return controller
    }

    /// Close a page from code (sign-in settled); no `onFinish` for it.
    static func close(_ controller: SFSafariViewController?) {
        guard let controller else { return }
        delegates[ObjectIdentifier(controller)] = nil
        if controller.presentingViewController != nil, !controller.isBeingDismissed { controller.dismiss(animated: true) }
    }
}

/// Status dot, uptime and memory of the in-process engine.
private struct EngineCard: View {
    @EnvironmentObject private var engine: NodeEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 14) {
                if case .running = engine.phase { StatusDot(state: .running, size: 8, halo: true) }
                else { Circle().fill(Palette.faint).frame(width: 8, height: 8) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail(now: context.date)).font(.footnote).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var title: String {
        switch engine.phase {
        case .starting: String(localized: "引擎启动中")
        case .running: String(localized: "引擎运行中")
        case .exited(let code): String(localized: "引擎已退出（\(code)）")
        case .unsupported: String(localized: "这台设备运行不了引擎")
        }
    }

    private func detail(now: Date) -> String {
        var parts: [String] = []
        if case .running = engine.phase, let since = engine.runningSince {
            let uptime = Duration.seconds(max(60, now.timeIntervalSince(since)))
            parts.append(String(localized: "已运行 \(uptime.formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)))"))
        }
        if let memory = Self.memoryFootprint() {
            parts.append(String(localized: "内存 \(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory))"))
        }
        return parts.joined(separator: " · ")
    }

    /// The app's physical footprint: Node runs in this process.
    private static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

/// The tail of the engine's console log.
private struct EngineLogView: View {
    let file: URL
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? String(localized: "（日志为空）") : text)
                .font(.caption2.monospaced())
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .background(Palette.grouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            LogPrivacyNote()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .navigationTitle("引擎日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新")
                ShareLink(item: file)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 96_000 ? size - 96_000 : 0)
        text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }
}

/// The way into 「分享 Fish Pocket」 at the top of 设置: the app's icon, so it reads as the app itself.
private struct ShareAppRow: View {
    var body: some View {
        HStack(spacing: 12) {
            AppIconMark(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("分享 Fish Pocket")
                Text("海报、二维码或链接").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// The rating, website, feedback and community links that close the 探索 tab, drawn there as its
/// other rows are (`ExploreTabView`), and 设置 in the system's look on an iPad before iOS 18,
/// which has no such tab (`SupportLinksSection`). Each opens in the browser.
struct SupportLink: Identifiable {
    let title: LocalizedStringKey
    let symbol: String
    let glyph: ExploreGlyph.Kind
    /// What it says on the right in 设置.
    let value: String
    /// The line under the name on the 探索 tab.
    let detail: Text
    let url: URL
    /// The App Store page: opening it settles the rating ask (`SupportPrompt`).
    var rates = false

    var id: URL { url }

    static var all: [SupportLink] {
        let site = AppLinks.site.host() ?? ""
        return [
            // The App Store page, from any install: rating it there is what helps most now.
            SupportLink(title: "给个评分", symbol: "star", glyph: .rate, value: "App Store",
                        detail: Text("在 App Store 打分、写评价"), url: AppLinks.appStore, rates: true),
            SupportLink(title: "官网", symbol: "safari", glyph: .site, value: site,
                        detail: Text(verbatim: site), url: AppLinks.site),
            SupportLink(title: "问题反馈", symbol: "exclamationmark.bubble", glyph: .feedback, value: "GitHub Issues",
                        detail: Text("在 GitHub Issues 提问题和建议"), url: AppLinks.repository.appending(path: "issues")),
            // The site's picture is swapped in place when the 7-day code expires: always the current one.
            SupportLink(title: "微信交流群", symbol: "bubble.left.and.bubble.right", glyph: .wechat,
                        value: String(localized: "扫码加群"), detail: Text("扫码加群"), url: AppLinks.wechatGroupCode),
            SupportLink(title: "Discord 社区", symbol: "person.2.circle", glyph: .discord, value: "discord.gg",
                        detail: Text(verbatim: "discord.gg"), url: AppLinks.discord),
            SupportLink(title: "关注我们", symbol: "at", glyph: .follow, value: "imsai.cc",
                        detail: Text(verbatim: "imsai.cc"), url: URL(string: "https://imsai.cc")!),
        ]
    }

    static let footer = Text("觉得好用的话，去 App Store 给个评分 ⭐️，这是对项目最大的支持。")
}

extension View {
    /// Opening the App Store page from a rating link settles the rating ask.
    @ViewBuilder func settlesRating(_ rates: Bool) -> some View {
        if rates {
            environment(\.openURL, OpenURLAction { _ in SupportPrompt.settle(); return .systemAction })
        } else {
            self
        }
    }
}

/// `SupportLink`s in 设置 on an iPad before iOS 18; the arrow says each leaves the app.
struct SupportLinksSection: View {
    var body: some View {
        Section {
            ForEach(SupportLink.all) { link in
                Link(destination: link.url) {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(link.value).lineLimit(1)
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
                    } label: {
                        Label(link.title, systemImage: link.symbol)
                    }
                }
                .settlesRating(link.rates)
            }
        } footer: {
            SupportLink.footer
        }
    }
}
