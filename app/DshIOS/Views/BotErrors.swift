import SwiftUI
import UserNotifications

/// ds-bot answers in English. What a person can run into from these pages is said in the
/// app's words; anything else stays as the plugin wrote it, which still names the problem.
enum BotErrorText {
    private typealias Rule = (pattern: String, text: ([String]) -> String)

    private static let rules: [Rule] = [
        // Bots
        (#"A Bot named (.+) already exists"#, { String(localized: "已经有一个叫\($0[1])的 Bot 了") }),
        (#"Name (.+) is not available"#, { String(localized: "「\($0[1])」这个名字已经被占用了") }),
        (#"A Main Bot cannot be deleted"#, { _ in String(localized: "主 Bot 不能删除，先取消它的主 Bot 身份") }),
        (#"The team needs at least one Main Bot"#, { _ in String(localized: "团队至少要有一个主 Bot") }),
        (#"(.+) is a Main Bot, so it cannot be private"#, { String(localized: "\($0[1])是主 Bot，不能设为私有") }),
        (#"(.+) is private, so it cannot be a Main Bot"#, { String(localized: "\($0[1])是私有 Bot，不能做主 Bot") }),
        (#"(.+) is private, so it cannot be copied"#, { String(localized: "\($0[1])是私有 Bot，不能复制") }),
        (#"(.+) needs a folder of its own to be private"#, { String(localized: "\($0[1])要有自己的文件夹才能设为私有") }),
        (#"(.+) is in a group chat, where every member"#, { String(localized: "\($0[1])还在群聊里，先把它移出群聊") }),
        (#"(.+) is a private Bot and cannot be in a group chat"#, { String(localized: "\($0[1])是私有 Bot，不能进群聊") }),
        (#"is in or around the folder of (.+), a private Bot"#, { String(localized: "这个文件夹和私有 Bot \($0[1])的文件夹重叠，换一个") }),
        (#"is in or around"#, { _ in String(localized: "这个文件夹和别的 Bot 用的文件夹重叠，换一个") }),
        (#"holds DeepSeek Harness data|is in DeepSeek Harness data"#, { _ in String(localized: "这个文件夹里是 App 自己的数据，不能用") }),
        (#"There is no folder at"#, { _ in String(localized: "这个文件夹不存在") }),
        (#"is a file, not a folder"#, { _ in String(localized: "这是个文件，不是文件夹") }),
        (#"The Bot is working"#, { _ in String(localized: "Bot 正在干活，等它做完或先让它停下") }),
        (#"That Bot has been deleted|Unknown Bot"#, { _ in String(localized: "这个 Bot 已经不在了") }),
        (#"That group chat has been deleted|Unknown group chat|No such Bot or group chat"#, { _ in String(localized: "这个群聊已经不在了") }),
        (#"No model is available"#, { _ in String(localized: "还没有可用的模型，先到设置里添加") }),
        (#"Pick a model before choosing a thinking level"#, { _ in String(localized: "先选模型，再选思考强度") }),
        (#"Thinking level .+ is not available|has no thinking levels"#, { _ in String(localized: "这个模型不支持这个思考强度") }),
        (#"Auto review applies to one Session only"#, { _ in String(localized: "自动审查只能用在单个会话上，不能设成 Bot 或群聊的权限") }),
        (#"This Bot has not called a model yet"#, { _ in String(localized: "这个 Bot 还没开始对话，先正常发一条消息") }),
        (#"Nothing kept closed for this Bot"#, { _ in String(localized: "这个 Bot 没有封存的内容") }),
        // Groups
        (#"A group chat needs at least two Bots"#, { _ in String(localized: "群聊至少要两个 Bot") }),
        (#"A group chat holds at most (\d+) Bots"#, { String(localized: "群聊最多 \($0[1]) 个 Bot") }),
        (#"Another group chat is already called "(.+)""#, { String(localized: "已经有一个叫「\($0[1])」的群聊了") }),
        (#"notice can hold at most (\d+) characters"#, { String(localized: "群公告最多 \($0[1]) 个字") }),
        (#"must be a member (of the group|to be the admin)"#, { _ in String(localized: "群主必须是群成员") }),
        (#"Hand the admin role to another member"#, { _ in String(localized: "先把群主交给别的成员") }),
        (#"No Bot is left in this group chat"#, { _ in String(localized: "群里已经没有 Bot 了") }),
        // Cards
        (#"This (question|view) is no longer open|This card was already answered"#, { _ in String(localized: "这张卡片已经处理过了") }),
        (#"This approval is no longer open"#, { _ in String(localized: "这个批准请求已经处理过了") }),
        (#"This proposal is no longer open"#, { _ in String(localized: "这个提议已经处理过了") }),
        (#"This request was already answered"#, { _ in String(localized: "这个请求已经处理过了") }),
        (#"This request is gone"#, { _ in String(localized: "这个请求已经不在了") }),
        (#"Nothing to send"#, { _ in String(localized: "没有可发送的内容") }),
        (#"Write a question|Type a question or a change first"#, { _ in String(localized: "先写下你的问题") }),
        (#"This message is no longer kept|No such message"#, { _ in String(localized: "这条消息已经不在了") }),
        (#"This file cannot be read here|No such attachment"#, { _ in String(localized: "这个文件在这里读不出来") }),
        (#"The model wrote nothing"#, { _ in String(localized: "模型没有返回内容，再试一次") }),
        // Keys
        (#"Paste a key first|Type the key first|Enter the API key"#, { _ in String(localized: "先粘贴 Key") }),
        (#"Paste a token first|Paste the bot token first"#, { _ in String(localized: "先粘贴令牌") }),
        (#"A key must have at least (\d+) characters"#, { String(localized: "密钥至少要 \($0[1]) 个字符") }),
        (#"A key can have at most"#, { _ in String(localized: "密钥太长了") }),
        (#"Paste only the key, not a NAME=value line"#, { _ in String(localized: "只粘贴密钥本身，不要带「名字=」") }),
        (#"Paste the key without quotes"#, { _ in String(localized: "粘贴密钥时不要带引号") }),
        (#"An API key has no spaces"#, { _ in String(localized: "API Key 里不能有空格或特殊字符") }),
        (#"A name uses capitals, digits, and underscores"#, { _ in String(localized: "名字只能用大写字母、数字和下划线，并以字母开头") }),
        (#"No such key|is not saved yet"#, { _ in String(localized: "找不到这个密钥") }),
        (#"Choose every Bot or a list of Bots"#, { _ in String(localized: "选所有 Bot，或者勾选几个 Bot") }),
        // Connectors
        (#"GitHub did not accept this token"#, { _ in String(localized: "GitHub 不接受这个令牌") }),
        (#"Could not reach GitHub"#, { _ in String(localized: "连不上 GitHub") }),
        (#"Sign-in timed out"#, { _ in String(localized: "登录超时了") }),
        (#"No (Google )?sign-in is waiting"#, { _ in String(localized: "没有等待中的登录") }),
        (#"Connector addresses must start with https://|addresses must start with https://"#, { _ in String(localized: "地址要以 https:// 开头") }),
        (#"Enter a valid HTTP or HTTPS URL|Enter the endpoint as an http or https address"#, { _ in String(localized: "请填写 http 或 https 开头的网址") }),
        (#"Name the connector"#, { _ in String(localized: "给连接器起个名字") }),
        (#"No such connector"#, { _ in String(localized: "找不到这个连接器") }),
        (#"Only added connectors can be removed"#, { _ in String(localized: "只有自己添加的连接器才能移除") }),
        (#"This connector does not sign in"#, { _ in String(localized: "这个连接器不需要登录") }),
        (#"This DSH cannot load (connectors|MCP servers)"#, { _ in String(localized: "这个版本加载不了连接器") }),
        (#"state mismatch|is not for this attempt"#, { _ in String(localized: "这个网址不是这一次登录的。重新登录，再把完整网址复制过来") }),
        (#"The address has no code|Paste the address or the code"#, { _ in String(localized: "粘贴登录完成后地址栏里的完整网址") }),
        (#"does not publish OAuth sign-in metadata"#, { _ in String(localized: "这个服务不支持这种登录方式") }),
        // The service turned down the plugin's attempt to register itself as a client (Figma
        // only lets clients it has approved register).
        (#"Dynamic Client Registration rejected \(HTTP (\d+)\)"#, { String(localized: "这个服务拒绝了这个应用的登录申请（HTTP \($0[1])），暂时连不上") }),
        (#"Enter the client ID"#, { _ in String(localized: "请填写 Client ID") }),
        (#"Google sign-in is not available"#, { _ in String(localized: "这个版本不支持 Google 登录") }),
        (#"(GitHub|Gmail|Telegram|WeChat|Slack|https?://\S+) answered (.+)"#, { String(localized: "\($0[1]) 返回了错误：\($0[2])") }),
        // Mail
        (#"The password was refused"#, { _ in String(localized: "密码被拒绝了。请用邮箱的授权码或应用专用密码。") }),
        (#"Could not reach the mail server"#, { _ in String(localized: "连不上邮件服务器") }),
        (#"Enter the IMAP and SMTP hosts"#, { _ in String(localized: "请填写 IMAP 和 SMTP 服务器") }),
        (#"Enter an email address"#, { _ in String(localized: "请填写邮箱地址") }),
        (#"Enter the authorization code or app password"#, { _ in String(localized: "请填写授权码或应用专用密码") }),
        (#"No such account"#, { _ in String(localized: "找不到这个邮箱") }),
        (#"SMTP connection|mail connection"#, { _ in String(localized: "和邮件服务器的连接断了，再试一次") }),
        (#"The password for (.+) is not saved"#, { String(localized: "\($0[1])的密码没有保存，重新添加这个邮箱") }),
        // Capabilities
        (#"Use a capability name with lowercase letters"#, { _ in String(localized: "名字只能用小写字母、数字和单个连字符，也不能和连接器重名") }),
        (#"A capability cannot change its kind"#, { _ in String(localized: "能力的类型不能改，删掉再新建一个") }),
        (#"No capability named (.+)\."#, { String(localized: "找不到叫 \($0[1]) 的能力") }),
        (#"Packs can include only|refers to an unavailable capability"#, { _ in String(localized: "组合里只能放已保存的 MCP 服务和技能") }),
        // Scheduled tasks
        (#"Automation tasks are off in DSH"#, { _ in String(localized: "自动化任务没有开启") }),
        (#"Give the task a name"#, { _ in String(localized: "给任务起个名字") }),
        (#"Say what the Bot should do"#, { _ in String(localized: "写下要 Bot 做什么") }),
        (#"Pick a time in the future"#, { _ in String(localized: "请选一个将来的时间") }),
        (#"Pick at least one day"#, { _ in String(localized: "至少选一天") }),
        (#"Pick a date and time|Pick a time of day|Pick when it runs"#, { _ in String(localized: "请选择运行的时间") }),
        (#"Repeat every 1 minute to 7 days"#, { _ in String(localized: "重复间隔要在 1 分钟到 7 天之间") }),
        (#"Keep the name under (\d+) characters"#, { String(localized: "名字不能超过 \($0[1]) 个字") }),
        (#"No such task"#, { _ in String(localized: "找不到这个任务") }),
        // Chat apps
        (#"Choose a Bot first"#, { _ in String(localized: "先选一个 Bot") }),
        (#"Choose a Bot or a group"#, { _ in String(localized: "选一个 Bot 或群聊") }),
        (#"(.+) is required"#, { String(localized: "请填写 \($0[1])") }),
        (#"This platform (is not available yet|has no QR login|signs in by scanning)"#, { _ in String(localized: "这个平台暂时还用不了") }),
        (#"No such IM bot|No such chat|No such platform"#, { _ in String(localized: "找不到这个连接") }),
        (#"rate limited"#, { _ in String(localized: "请求太频繁，稍后再试") }),
        (#"did not answer"#, { _ in String(localized: "对方没有及时响应，稍后再试") }),
        (#"refused the token|does not belong to a .+ bot|do not belong to a Slack bot|did not say who this token"#, { _ in String(localized: "这个令牌不对，检查后重新粘贴") }),
        (#"without WebSocket|could not open a socket|refused the socket"#, { _ in String(localized: "这台设备暂时连不上这个平台") }),
        // Memory
        (#"Memory is turned off"#, { _ in String(localized: "记忆功能没有开启") }),
        (#"Learning is turned off"#, { _ in String(localized: "学习功能没有开启") }),
        (#"That change is already restored"#, { _ in String(localized: "这条改动已经撤销过了") }),
        (#"it looks like a key, token, password"#, { _ in String(localized: "这条内容像是密钥或证件号，记忆里不保存这类信息") }),
        (#"cannot be restored|not a change that can be restored|not in the change log|cannot be (put back|taken out)"#, { _ in String(localized: "这条改动撤销不了") }),
        (#"already has \d+ topics"#, { _ in String(localized: "记忆的主题已经到上限了，记到已有的主题里") }),
        // Looks
        (#"[Aa]vatar image is too large"#, { _ in String(localized: "头像图片太大了") }),
        (#"avatar library holds at most (\d+) photos"#, { String(localized: "头像库最多存 \($0[1]) 张照片") }),
        (#"Avatar images must be|The avatar must be"#, { _ in String(localized: "头像要用 PNG、JPEG、WebP 或 GIF 图片") }),
        // The team itself
        (#"This host cannot save the Bot team|cannot change now"#, { _ in String(localized: "另一个 DSH 正在管理这支团队，这里暂时只能看") }),
        (#"Unknown endpoint"#, { _ in String(localized: "这个版本的 Bot 插件不支持这个操作") }),
        (#"Unknown part|Unknown conversation"#, { _ in String(localized: "找不到这段对话") }),
        (#"This DeepSeek Harness (cannot list folders|has no folder chooser)"#, { _ in String(localized: "这里不能浏览文件夹") }),
    ]

    private static let compiled: [(NSRegularExpression, ([String]) -> String)] = rules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern)).map { ($0, rule.text) }
    }

    static func text(_ message: String) -> String {
        let range = NSRange(message.startIndex..., in: message)
        for (regex, text) in compiled {
            guard let match = regex.firstMatch(in: message, range: range) else { continue }
            let groups = (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: message).map { String(message[$0]) } ?? ""
            }
            return text(groups)
        }
        return message
    }
}

/// Something waits on the user in a chat they are not looking at. In the app it is a toast
/// with a way there; away from it, a notification, only when the user already allows them
/// (this never asks: notifications are switched on in 设置 › 本机能力).
@MainActor
enum BotNotifier {
    static func announce(_ text: String, detail: String, app: AppModel, open: @escaping () -> Void) {
        if UIApplication.shared.applicationState == .active {
            Haptics.tap()
            app.showToast(text, action: String(localized: "去看看"), duration: 6, perform: open)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = text
            content.body = detail
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "bot-approval-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }
}
