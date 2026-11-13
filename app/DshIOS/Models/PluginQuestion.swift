import Foundation

/// How an install ended and what the app saw of it, kept for 询问 AI.
struct InstallRecord: Equatable {
    enum Outcome { case failed, unknown, done }
    let outcome: Outcome
    let title: String
    /// One fact per line, the log last.
    let details: [String]
}

/// 询问 AI: the first message of a new conversation about a plugin. It carries what the app knows
/// of the plugin and of its last install, so the agent starts from the record, not from a retelling.
enum PluginQuestion {
    /// Not installed yet: a quick question. The facts below usually answer it; reading the
    /// source first only makes the reader wait.
    static func introduce(_ title: String, details: [String]) -> String {
        compose(String(localized: "简单介绍一下插件「\(title)」：它是做什么的、怎么用、在这台设备上能不能用。先根据下面的信息简短回答，不用一上来就读源代码；信息不够再去看它的说明文档。"), details)
    }

    static func failed(_ title: String, details: [String]) -> String {
        compose(String(localized: "我安装插件「\(title)」失败了。帮我找出原因，能修好就直接修，修不了就告诉我该怎么办。"), details)
    }

    /// The result never arrived.
    static func unknown(_ title: String, details: [String]) -> String {
        compose(String(localized: "我安装插件「\(title)」后没有拿到结果。帮我确认它装上了没有，没装上就找出原因。"), details)
    }

    /// Installed: where it is and how to use it, from what the app knows; digging in only when
    /// its status says it isn't running.
    static func installed(_ title: String, details: [String]) -> String {
        compose(String(localized: "插件「\(title)」我已经装好了，它是做什么的、在哪里用？先根据下面的信息简短回答，不用一上来就读源代码；如果状态显示它没在运行，再帮我查原因。"), details)
    }

    static func ask(_ record: InstallRecord, more: [String] = []) -> String {
        switch record.outcome {
        case .failed: failed(record.title, details: more + record.details)
        case .unknown: unknown(record.title, details: more + record.details)
        case .done: installed(record.title, details: more + record.details)
        }
    }

    private static func compose(_ ask: String, _ details: [String]) -> String {
        ([ask, "", String(localized: "下面是 App 记录的插件和安装信息：")] + details).joined(separator: "\n")
    }

    /// The end of a command's output: what failed is said last, and a whole log would bury the question.
    static func tail(_ output: String, lines limit: Int = 80, characters: Int = 6000) -> String {
        let whole = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var kept = whole.split(separator: "\n", omittingEmptySubsequences: false).suffix(limit).joined(separator: "\n")
        if kept.count > characters { kept = String(kept.suffix(characters)) }
        return kept.count < whole.count ? "…\n" + kept : kept
    }
}

extension PluginPackage {
    /// What the plugin list says of an installed package, as 询问 AI tells it.
    var questionDetails: [String] {
        var lines = [String(localized: "插件：\([name, version].compactMap { $0 }.joined(separator: "@"))")]
        if !enabled { lines.append(String(localized: "状态：已停用")) }
        else if problem { lines.append(String(localized: "状态：已启用，但没有在运行")) }
        else { lines.append(String(localized: "状态：已启用，正在运行")) }
        if let source { lines.append(String(localized: "安装来源：\(source)")) }
        if let error {
            let code = error["code"].string.map { " [\($0)]" } ?? ""
            lines.append(String(localized: "插件列表报告的错误：\(managementText(error))\(code)"))
        }
        for row in rows { lines.append(String(localized: "组件 \(row.moduleName)：\(row.stateText)")) }
        return lines
    }
}
