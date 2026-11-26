import Foundation

/// 「新功能」: what a version brings, shown once to those who updated to it, and kept under
/// 设置 → 关于. It is the highlights a reader would notice, not the change log, so a fix-only
/// release adds nothing here and shows nothing. An entry belongs to a version, or to one build
/// of it when a later build (TestFlight) brings more. Whoever reaches a version sees all of its
/// entries at once; only a later build of a version already seen shows again, and then says
/// which build, the way TestFlight does, so it doesn't read as the same notice twice. App Store
/// installs get one build a version and see it once. Fresh installs see nothing they already have.
@MainActor
enum WhatsNew {
    struct Feature: Identifiable {
        /// An SF Symbol.
        let symbol: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        var id: String { symbol }
    }

    struct Release: Identifiable {
        /// As `MARKETING_VERSION` writes it.
        let version: String
        /// The first build that has this entry; nil for every build of the version. Shown only on
        /// a notice for a later build of a version already seen.
        var build: Int?
        let features: [Feature]
        var id: String { "\(version) (\(build ?? 0))" }

        /// 1.1.0 reads as 1.1, and a build as TestFlight writes it: 1.1 (20).
        var label: String {
            let short = version.hasSuffix(".0") && version.split(separator: ".").count > 2 ? String(version.dropLast(2)) : version
            return build.map { "\(short) (\($0))" } ?? short
        }
    }

    /// Said only by a build that has the account: one made without the service's address
    /// (a fork, a local build) shows it nowhere, so has nothing to announce.
    private static var fishPocketAccount: [Feature] {
        guard FishPocketAPI.available else { return [] }
        return [
            Feature(symbol: "sparkles",
                    title: "Fish Pocket 账号",
                    detail: "不需要 DeepSeek 账号，也不需要 API Key：登录 Fish Pocket 账号，就能用账号里的额度对话，按用量扣积分。额度在 App Store 版本里购买，买了不会过期。入口在设置 → 连接方式。"),
        ]
    }

    /// Newest first. Until the app reaches an entry's version (and build, when it names one),
    /// the entry is not shown. Entries of one version are shown together, newest first.
    static let releases: [Release] = [
        Release(version: "1.2.2", build: 125, features: [
            Feature(symbol: "phone.and.waveform",
                    title: "和智能体打电话",
                    detail: "会话和 Bot 私聊里，输入框空着时点右边的波形按钮就能通话：直接开口说，它用语音回答，它说话时你随时可以打断。用的是你自己的火山引擎 API Key，在设置 → 语音通话里配置。"),
            Feature(symbol: "text.bubble",
                    title: "干活时也能插话",
                    detail: "智能体正在干活时直接发消息，它做完手头这一步就会看到并调整，不用等它跑完。插话和排队的消息显示在对话里，送到之前可以取消。"),
            Feature(symbol: "square.2.layers.3d",
                    title: "Siri 和快捷指令",
                    detail: "对 Siri 说「用 Fish Pocket 打开大肥鱼」，就能直接进入和这个 Bot 的聊天；也能在「快捷指令」里设成自动化，到点打开某个 Bot 或 Mini App。怎么设置见探索 → 快捷指令（iOS 17 的 iPad 上在侧边栏）。"),
            Feature(symbol: "doc.text.magnifyingglass",
                    title: "文件点开就能看",
                    detail: "对话里的文件点一下就能预览：Word、Excel、PPT 直接显示内容，Markdown 排好版显示，文本带行号。"),
        ]),
        Release(version: "1.2.2", build: 124, features: [
            Feature(symbol: "photo.badge.plus",
                    title: "让智能体给你画图",
                    detail: "在对话里说「画一张…」就能生成图片，也能改图、一次出一组。Gemini、OpenAI、即梦、通义、Grok、智谱和本地 ComfyUI 都能用；不想填 API Key，也可以登录 ChatGPT、Grok 或 Google 订阅账号。在设置 → 生图里配置。"),
            Feature(symbol: "pencil.tip.crop.circle",
                    title: "圈哪改哪",
                    detail: "点开对话里的图片，用底部的「标注」圈出要改的地方，再说「把这里换成…」，智能体会照着你圈的位置改。"),
        ]),
        Release(version: "1.2.1", build: 114, features: [
            Feature(symbol: "tray.and.arrow.down",
                    title: "把 DeepSeek 的聊天记录搬过来",
                    detail: "在 DeepSeek 官网导出聊天记录，新会话页点「导入 DeepSeek 会话」选中压缩包，以前的对话连同思考过程和图片都会出现在会话列表里，点开就能接着聊。"),
            Feature(symbol: "person.3",
                    title: "几个智能体分工协作",
                    detail: "在输入框的「+」里打开「智能体团队协作」，复杂的任务会拆给多个智能体，用一张共享任务板分工推进。效果更好，token 也用得更多。"),
            Feature(symbol: "hammer",
                    title: "用对话定制 Fish Pocket",
                    detail: "新会话选「创造模式」，让 Agent 替你写插件：加新工具、接入外部服务，或者把工具和提示词组合成一个自己的模式。"),
            Feature(symbol: "doc.on.clipboard",
                    title: "直接粘贴图片",
                    detail: "在照片或别的 App 里拷贝一张图，回到输入框长按选「粘贴」，图片就放进附件里，和从相册选的一样。"),
            Feature(symbol: "plus.app",
                    title: "网页版也能放到主屏幕",
                    detail: "在网页版右上角的「···」里选「添加到主屏幕」，以后点这个图标就进 Fish Pocket，直接打开网页版。"),
        ]),
        Release(version: "1.2.1", build: 112, features: [
            Feature(symbol: "globe",
                    title: "看懂模型的思考过程",
                    detail: "在「插件」里启用官方的「思考过程翻译」后，点开思考全文默认显示译文，可以随时切回原文；思考还在进行时也会边出边译。"),
        ]),
        // 105 to 111 never went out on their own: one entry, its first build. 操控手机 leads.
        Release(version: "1.2.1", build: 110, features: [
            Feature(symbol: "hand.tap",
                    title: "让智能体操控你的 iPhone、iPad",
                    detail: "装好开源的 iCTRL 后，智能体能像你一样操控 iPhone、iPad：点按、输入、读取屏幕，在各个 App 之间替你办事。「探索」里的「操控手机」可以查看状态、一键启动，还有设置教程。"),
            Feature(symbol: "rectangle.bottomthird.inset.filled",
                    title: "底部标签栏",
                    detail: "首页改成苹果的标签栏，会话、Bot、Mini Apps、探索一点就到，设置在探索页右上角。插件、连接器、本机能力、操控手机、远程控制都在「探索」里，搜索放进了会话列表。iPad 和 iPhone Duo 上，标签栏会自动放到顶部或变成侧边栏。"),
            Feature(symbol: "apps.iphone",
                    title: "做自己的 Mini App",
                    detail: "在对话里让 Agent 做个小工具或小游戏，做好就放进「Mini Apps」里，点开就能用，也能放到主屏幕上。先试试自带的倒数日、番茄钟和水果翻翻。"),
            Feature(symbol: "record.circle",
                    title: "回看智能体的操作",
                    detail: "智能体操作其他 App 时会把屏幕录下来，放在对话里，默认两倍速回看。分享时会生成一段带 Fish Pocket 外框的视频。"),
            Feature(symbol: "photo.on.rectangle",
                    title: "把对话分享成图片",
                    detail: "点会话标题的菜单，或长按一条回复，选「分享为图片」。挑几轮对话画成一张长图，发给别人或存进相册，密钥会自动打码。"),
        ] + fishPocketAccount + [
            Feature(symbol: "app.badge",
                    title: "换个 App 图标",
                    detail: "设置 → App 图标里可以把主屏幕上的图标换成别的颜色或贴纸版的大肥鱼，也可以换成不带人物的鲸鱼图标，或者只写着 Fish Pocket 的字标。"),
            Feature(symbol: "quote.opening",
                    title: "引用消息再提问",
                    detail: "长按一条消息选「引用」，也可以在「选择文本」里选中一段再引用。引用显示在输入框上方，和你的问题一起发给智能体。"),
        ]),
        Release(version: "1.2.1", build: 103, features: [
            Feature(symbol: "character.bubble",
                    title: "界面支持繁体中文",
                    detail: "系统语言是繁体中文时自动切换，用词按台湾的习惯；也可以在设置 → 语言里选繁體中文。"),
        ]),
        Release(version: "1.2.1", features: [
            Feature(symbol: "square.and.arrow.down",
                    title: "从别的 App 分享进来",
                    detail: "在微信、相册、Safari 里点「分享」选 Fish Pocket，文字、链接、图片和文件会放进新对话、某个 Bot 或群聊的输入框，确认后再发送。"),
        ]),
        Release(version: "1.2.0", build: 43, features: [
            Feature(symbol: "globe",
                    title: "界面支持日语和韩语",
                    detail: "跟随系统语言自动切换，也可以在设置 → 语言里选日本語或한국어。"),
        ]),
        Release(version: "1.2.0", build: 42, features: [
            Feature(symbol: "lock.iphone",
                    title: "电脑上的会话也上锁屏和灵动岛",
                    detail: "从手机发起或接管的远程会话，在进行、等你允许还是已完成，锁屏和灵动岛上都看得到；审批可以直接在锁屏上点允许。"),
            Feature(symbol: "square.grid.2x2",
                    title: "小组件里也有远程会话",
                    detail: "主屏幕和锁屏小组件的会话列表，把电脑上的会话和本机的放在一起。"),
        ]),
        Release(version: "1.2.0", features: [
            Feature(symbol: "laptopcomputer.and.iphone",
                    title: "在手机上管电脑里的智能体",
                    detail: "登录 Agents Anywhere 后，电脑上的 Codex、Claude Code 和 DeepSeek Harness 会话出现在侧边栏，和本机会话放在一起。"),
            Feature(symbol: "checkmark.shield",
                    title: "不回电脑也能回应审批和提问",
                    detail: "跟进进度、接着聊、允许或拒绝操作、随时打断，都在手机上完成。"),
            Feature(symbol: "rectangle.stack",
                    title: "按设备、项目或时间整理会话",
                    detail: "侧边栏可以按设备分组，每条会话标明是哪台电脑、哪个智能体。入口在侧边栏的「远程控制」。"),
            Feature(symbol: "person.2",
                    title: "Bot 模式",
                    detail: "一支常驻的 Bot 团队：可以私聊，可以拉群一起商量，也能到点自己开工。入口在侧边栏。"),
            Feature(symbol: "face.smiling",
                    title: "每个 Bot 有自己的样子",
                    detail: "新建时挑一个形象和颜色，它思考、搜索、干活的时候各有各的神态。"),
            Feature(symbol: "point.3.connected.trianglepath.dotted",
                    title: "连接器",
                    detail: "GitHub、Notion 这些服务连一次，普通会话和 Bot 都能用。入口也在侧边栏。"),
            Feature(symbol: "arrow.uturn.backward",
                    title: "回到上次的会话",
                    detail: "重新打开 App，直接回到上次所在的会话或 Bot 聊天。"),
            Feature(symbol: "photo.on.rectangle.angled",
                    title: "让智能体帮你整理照片",
                    detail: "建相簿、收藏、隐藏、把图存进相册或删掉，在对话里说一声就行。删照片前 iOS 会再问你一次。"),
            Feature(symbol: "sparkles",
                    title: "插件的事，一键询问 AI",
                    detail: "在插件详情页或安装失败时点一下，新会话会带上插件和安装记录帮你排查。"),
            Feature(symbol: "iphone",
                    title: "智能体能用 iPhone 自带的能力",
                    detail: "查日历、建提醒、定闹钟、找联系人、读健康数据，在对话里直接说就行。"),
            Feature(symbol: "hand.raised",
                    title: "每项能力由你自己打开",
                    detail: "侧边栏新增「本机能力」，逐项开关，也能看到哪些能力被用过。"),
            Feature(symbol: "photo",
                    title: "聊天里直接显示图片",
                    detail: "回复里带的图片会显示在对话中，不再只是一行链接。"),
        ]),
        Release(version: "1.1.0", features: [
            Feature(symbol: "square.grid.2x2",
                    title: "主屏幕和锁屏小组件",
                    detail: "不打开 App 也能看到会话在进行、已完成还是在等你允许，轻点回到对话。"),
            Feature(symbol: "switch.2",
                    title: "控制中心、Siri 和快捷指令",
                    detail: "从控制中心按钮、Siri 或快捷指令直接开始新对话。"),
            Feature(symbol: "chevron.left.forwardslash.chevron.right",
                    title: "内置 Python",
                    detail: "插件和终端都能直接运行 Python 脚本，不用另外安装。"),
            Feature(symbol: "globe",
                    title: "在 App 内切换语言",
                    detail: "在设置里直接选择界面语言，新增西班牙语。"),
        ]),
    ]

    /// The newest entry dealt with: shown, or already there when the app was installed.
    private static let seenVersionKey = "dsh.whatsNew.version"
    private static let seenBuildKey = "dsh.whatsNew.build"

    /// Everything this build has to say about its version, for 设置 → 关于.
    static var current: Release? {
        guard let newest = reached.first else { return nil }
        return merged(reached.filter { same($0.version, newest.version) }, version: newest.version, build: nil)
    }

    /// At launch, before anything this launch writes. With no record yet, the install is either
    /// new, and has seen everything so far, or from before the record was kept (1.0.x), and has
    /// seen nothing: those leave their own settings behind (`dsh.theme.preference` once the
    /// engine answers, `dsh.currentWorkspace` with the first conversation).
    static func noteLaunch() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: seenVersionKey) == nil else { return }
        let earlier = defaults.object(forKey: ThemePreference.key) != nil || defaults.object(forKey: "dsh.currentWorkspace") != nil
        if earlier { markSeen("0", 0) } else { markSeen(version, build) }
    }

    /// What to show now, once: this version's entries not seen yet, together.
    static func take() -> Release? {
        let defaults = UserDefaults.standard
        guard let newest = reached.first, let seenVersion = defaults.string(forKey: seenVersionKey) else { return nil }
        let seenBuild = defaults.integer(forKey: seenBuildKey)
        let unseen = reached.filter { same($0.version, newest.version) && isAfter($0.version, $0.build ?? 0, than: seenVersion, seenBuild) }
        guard let latest = unseen.first else { return nil }
        markSeen(newest.version, newest.build ?? 0)
        // Something of this version was seen before: name the build this notice is for.
        let again = same(seenVersion, newest.version)
        return merged(unseen, version: newest.version, build: again ? latest.build : nil)
    }

    /// The entries this build has reached, newest first.
    private static var reached: [Release] {
        // An entry with nothing to say in this build (the account's, in a build without it) is skipped.
        releases.filter { !$0.features.isEmpty && !isAfter($0.version, $0.build ?? 0, than: version, build) }
    }

    private static func merged(_ entries: [Release], version: String, build: Int?) -> Release {
        Release(version: version, build: build, features: entries.flatMap(\.features))
    }

    private static func same(_ version: String, _ other: String) -> Bool {
        !AppVersion.isNewer(version, than: other) && !AppVersion.isNewer(other, than: version)
    }

    private static func markSeen(_ version: String, _ build: Int) {
        UserDefaults.standard.set(version, forKey: seenVersionKey)
        UserDefaults.standard.set(build, forKey: seenBuildKey)
    }

    /// Version first, then build.
    private static func isAfter(_ version: String, _ build: Int, than otherVersion: String, _ otherBuild: Int) -> Bool {
        if AppVersion.isNewer(version, than: otherVersion) { return true }
        if AppVersion.isNewer(otherVersion, than: version) { return false }
        return build > otherBuild
    }

    // UI checks in DEBUG builds: `simctl launch … -dshVersion 1.1.0 -dshBuild 20` act as that build.
    private static var version: String {
        #if DEBUG
        if let version = UserDefaults.standard.string(forKey: "dshVersion") { return version }
        #endif
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static var build: Int {
        #if DEBUG
        if let build = UserDefaults.standard.string(forKey: "dshBuild").flatMap(Int.init) { return build }
        #endif
        return (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
    }
}
