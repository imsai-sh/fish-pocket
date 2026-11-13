import UIKit
import WebKit

/// browser 能力的实现：让智能体操作会话自己的浏览器，也就是「工作台 → 浏览器」里那一个。
///
/// 读页面和点、填、选靠 page-agent 的 page controller（`PageController.js`，由
/// `scripts/build-page-controller.sh` 打包）。它整个跑在网页里，是 iOS 上唯一走得通
/// 的浏览器自动化办法：这里没有 Chromium，靠 CDP、WebDriver 的方案都用不了。
///
/// 参数在 `caps_browser.m` 里查过了，这里只做事。发给模型的话都是英文，和其他能力一致。
@objc final class BrowserAgent: NSObject {
    @objc static let shared = BrowserAgent()

    private override init() { super.init() }

    /// 启动时登记，和天气、闹钟挨着，在引擎起来之前。
    @objc static func install() {
        DshBrowserSetProvider(shared)
    }

    @MainActor
    private static func perform(_ op: String, _ args: [String: Any]) async throws -> [String: Any] {
        guard let session = args["session"] as? String else { throw BrowserAgentError("missing session") }
        guard let app = EngineConnection.shared.app else {
            throw BrowserAgentError("the app is still connecting to its engine; try again in a moment")
        }
        // 子智能体用发起它的那个会话的浏览器。
        let owner = owner(of: session, in: app)
        let browser = BrowserModel.session(owner, origin: app.client.origin)
        let named = args["tab"] as? String

        // 标签页本身的操作：不碰网页，不用排队。
        switch op {
        case "tabs":
            return tabsAnswer(browser)
        case "close_tab":
            guard let id = named, let tab = browser.tab(id) else {
                throw BrowserAgentError("There is no tab '\(named ?? "")'. Use `tabs` to see the open ones.")
            }
            browser.close(tab)
            var answer = tabsAnswer(browser)
            answer["action"] = "Closed tab \(id)."
            return answer
        case "select_tab":
            let tab = try browser.agentTarget(named, opening: false)
            browser.select(tab)
            browser.agentUses(tab)
            guard tab.started else {
                var answer = tabsAnswer(browser)
                answer["action"] = "Tab \(tab.id) is in front now. It is blank: `open` a URL in it."
                return answer
            }
        case "new_tab":
            let tab = browser.newTab()
            browser.agentUses(tab)
            guard args["url"] is String else {
                var answer = tabsAnswer(browser)
                answer["action"] = "Opened tab \(tab.id), blank, in front. `open` a URL in it."
                return answer
            }
        default:
            break
        }

        let tab = try browser.agentTarget(named, opening: op == "open" || op == "new_tab")
        browser.agentUses(tab)
        // 为了省内存放掉的页面，先回到原来的地址。
        let revived = tab.page == nil
        let page = browser.revive(tab)
        var answer = try await page.serially {
            page.presence.began(op == "new_tab" ? "open" : op == "select_tab" ? "read" : op, driver: session)
            // The panel's stop button ends the turn of the conversation that owns this browser.
            page.presence.stop = { [weak app] in
                Task { try? await app?.client.call("session/cancel", ["request": ["sessionId": .string(owner)]]) }
            }
            defer { page.presence.ended() }
            if revived { page.attachIfDetached(); await page.settle(navigating: true) }
            switch op {
            case "open", "new_tab": return try await page.agentOpen(args["url"] as? String ?? "", desktop: args["desktop"] as? Bool)
            case "read", "select_tab": return try await page.agentRead()
            case "click", "type", "select", "scroll": return try await page.agentAct(op, args)
            case "back", "forward", "reload": return try await page.agentNavigate(op, desktop: args["desktop"] as? Bool)
            case "evaluate": return try await page.agentEvaluate(args["script"] as? String ?? "")
            case "screenshot": return try await page.agentScreenshot()
            default: throw BrowserAgentError("browser has no operation '\(op)'")
            }
        }
        // Which tab this was, so the agent can tell when the user has another in front.
        answer["tab"] = tab.id
        answer["tabCount"] = browser.tabs.count
        answer["frontTab"] = browser.selectedId ?? NSNull()
        if op == "select_tab" { answer["action"] = "Tab \(tab.id) is in front now." }
        if op == "new_tab" { answer["action"] = "Opened tab \(tab.id) in front." }
        return answer
    }

    /// Every tab: its id, title and address, which one is in front and which one the agent works in.
    @MainActor
    private static func tabsAnswer(_ browser: BrowserModel) -> [String: Any] {
        let tabs: [[String: Any]] = browser.tabs.map { tab in
            [
                "id": tab.id,
                "title": tab.title ?? "",
                "url": tab.url ?? "",
                "front": tab.id == browser.selectedId,
                "yours": tab.id == browser.agentTabId,
                "loading": tab.page?.loading ?? false,
            ]
        }
        return ["tabs": tabs]
    }
}

extension BrowserAgent {
    /// 子智能体用的是发起它的那个会话的浏览器：用户只在主会话里看得到工作台。
    @MainActor
    static func owner(of session: String, in app: AppModel) -> String {
        var id = session
        var seen: Set<String> = [id]
        while let parent = app.sessions[id]?.parentId, seen.insert(parent).inserted { id = parent }
        return id
    }
}

extension BrowserAgent: DshBrowserProviding {
    func performOperation(
        _ op: String,
        arguments args: [String: Any],
        completion done: @escaping ([String: Any]?, String?) -> Void
    ) {
        Task { @MainActor in
            do {
                done(try await Self.perform(op, args), nil)
            } catch let error as BrowserAgentError {
                done(nil, error.message)
            } catch {
                done(nil, error.localizedDescription)
            }
        }
    }
}

struct BrowserAgentError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - 智能体的操作

extension BrowserPage {
    /// 注入脚本住的地方。和网页自己的脚本隔开：网页看不到 `__dshBrowser`，也改不了它；
    /// DOM 是共享的，点击和输入照样落到网页上。
    static let agentWorld = WKContentWorld.world(name: "dsh-browser")

    /// 每个页面加载完都注入一次。找不到文件就不注入，`read` 会说读不了。
    static let controllerScript: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "PageController", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: agentWorld)
    }()

    /// `desktop` asks for the site's desktop or mobile version, and the choice stays with the site, as
    /// the user's own from the bar's menu does.
    func agentOpen(_ input: String, desktop: Bool?) async throws -> [String: Any] {
        let url: URL
        switch Self.parse(input, applicationOrigin: origin) {
        case .success(let parsed): url = parsed
        case .failure(let refusal): throw BrowserAgentError(refusal.agentMessage)
        }
        if let desktop { Self.setDesktop(desktop, for: url) }
        attachIfDetached()
        go(url.absoluteString)
        await settle(navigating: true)
        return try await agentRead()
    }

    func agentRead() async throws -> [String: Any] {
        attachIfDetached()
        guard webView.url != nil else {
            throw BrowserAgentError("No page is open in this tab yet. Use `open` with a URL first.")
        }
        if let loadFailure {
            throw BrowserAgentError("The page did not load: \(loadFailure.localizedDescription) (\(loadFailure.domain) \(loadFailure.code)).")
        }
        let value: Any?
        do {
            value = try await run("return await __dshBrowser.read()", timeout: 15)
        } catch {
            throw BrowserAgentError(unreadable(error))
        }
        guard var state = value as? [String: Any] else {
            throw BrowserAgentError("The page could not be read. It may not be an HTML page.")
        }
        state["loading"] = webView.isLoading
        state["desktop"] = desktop
        return state
    }

    /// click / type / select / scroll，做完等页面稳定，再把新的页面读回去。
    func agentAct(_ op: String, _ args: [String: Any]) async throws -> [String: Any] {
        attachIfDetached()
        guard webView.url != nil else {
            throw BrowserAgentError("No page is open in this tab yet. Use `open` with a URL first.")
        }
        let index = (args["index"] as? NSNumber)?.intValue
        if op != "scroll" {
            // 编号来自上一次 read。页面换过以后旧编号对不上，直接点会点错东西，所以先拦下来。
            let indexed = (try? await run("return __dshBrowser.indexed()", timeout: 5)) as? Bool ?? false
            if !indexed {
                throw BrowserAgentError("This page has not been read since it loaded, so its element numbers are unknown. Call `read` first and use the numbers it shows.")
            }
        }
        let before = webView.url
        let body: String
        var arguments: [String: Any] = [:]
        switch op {
        case "click":
            body = "return await __dshBrowser.click(index)"
            arguments = ["index": index ?? 0]
        case "type":
            body = "return await __dshBrowser.type(index, text)"
            arguments = ["index": index ?? 0, "text": args["text"] as? String ?? ""]
        case "select":
            body = "return await __dshBrowser.select(index, option)"
            arguments = ["index": index ?? 0, "option": args["option"] as? String ?? ""]
        default:
            let down = (args["direction"] as? String ?? "down") != "up"
            let pages = (args["pages"] as? NSNumber)?.doubleValue ?? 1
            body = "if (!__dshBrowser.indexed()) await __dshBrowser.read(); return await __dshBrowser.scroll(down, pages, undefined, index ?? undefined)"
            arguments = ["down": down, "pages": pages, "index": index.map { $0 as Any } ?? NSNull()]
        }

        var message: String
        do {
            let result = try await run(body, arguments: arguments, timeout: 15) as? [String: Any]
            message = result?["message"] as? String ?? "\(op) done."
            if result?["success"] as? Bool == false { throw BrowserAgentError(message) }
        } catch let error as BrowserAgentError {
            throw error
        } catch {
            // 点了链接或提交了表单，页面在脚本返回前就换掉了：这是点成功了，不是失败。
            guard webView.isLoading || webView.url != before else { throw BrowserAgentError(unreadable(error)) }
            message = "\(op) done; the page then started loading \(webView.url?.absoluteString ?? "a new page")."
        }
        await settle(navigating: false)
        var state = try await agentRead()
        state["action"] = message
        return state
    }

    func agentNavigate(_ op: String, desktop: Bool?) async throws -> [String: Any] {
        attachIfDetached()
        switch op {
        case "back":
            guard webView.canGoBack else { throw BrowserAgentError("There is no earlier page in this tab.") }
            back()
        case "forward":
            guard webView.canGoForward else { throw BrowserAgentError("There is no later page in this tab.") }
            forward()
        default:
            guard webView.url != nil || lastURL != nil else {
                throw BrowserAgentError("No page is open in this tab yet. Use `open` with a URL first.")
            }
            if let desktop, let url = page ?? lastURL.flatMap(URL.init(string:)) { Self.setDesktop(desktop, for: url) }
            reload()
        }
        await settle(navigating: true)
        return try await agentRead()
    }

    /// 在网页自己的环境里跑一段脚本（能看到网页的全局变量），把返回值按 JSON 带回去。
    func agentEvaluate(_ script: String) async throws -> [String: Any] {
        attachIfDetached()
        guard webView.url != nil else {
            throw BrowserAgentError("No page is open in this tab yet. Use `open` with a URL first.")
        }
        let body = """
        const __value = await (async () => {
        \(script)
        })();
        return __value === undefined ? null : JSON.stringify(__value);
        """
        do {
            let value = try await run(body, in: .page, timeout: 30)
            return ["result": (value as? String) ?? NSNull(), "url": webView.url?.absoluteString ?? ""]
        } catch let error as BrowserAgentError {
            throw error
        } catch {
            let info = (error as NSError).userInfo
            let detail = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw BrowserAgentError("The script threw: \(detail)")
        }
    }

    /// 屏幕上能看到的那一截，就是用户在工作台里会看到的样子。
    ///
    /// 按 2 倍出图：3 倍的原图一张一两 MB，模型那头反正要缩；1 倍的小字又糊。JPEG 是因为
    /// 网页截图多是照片和渐变，PNG 要大好几倍。存进附件、按模型缩放是引擎的事。
    func agentScreenshot() async throws -> [String: Any] {
        attachIfDetached()
        guard webView.url != nil else {
            throw BrowserAgentError("No page is open in this tab yet. Use `open` with a URL first.")
        }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else {
            throw BrowserAgentError("The browser has no size yet, so there is nothing to capture. Try again in a moment.")
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let once = Once()
        let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                guard once.claim() else { return }
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: BrowserAgentError(
                        "The screenshot failed: \(error?.localizedDescription ?? "WebKit returned no image")."))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard once.claim() else { return }
                continuation.resume(throwing: BrowserAgentError(
                    "The screenshot did not finish within 10 seconds. The app may be in the background."))
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: snapshot.size, format: format).image { _ in
            snapshot.draw(in: CGRect(origin: .zero, size: snapshot.size))
        }
        guard let data = image.jpegData(compressionQuality: 0.75) else {
            throw BrowserAgentError("The screenshot could not be encoded.")
        }
        return [
            "data": data.base64EncodedString(),
            "mediaType": "image/jpeg",
            "url": webView.url?.absoluteString ?? "",
            "title": webView.title ?? "",
        ]
    }

    // MARK: 等待

    /// 等页面安静下来，有上限。导航可能在点击之后才开始，所以先给它一点时间冒头；
    /// 加载完再留一小段，让脚本渲染的页面把内容画出来。
    func settle(navigating: Bool) async {
        if !navigating { try? await Task.sleep(for: .milliseconds(300)) }
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// 调一段脚本，最多等 `timeout` 秒。网页卡住、App 被切到后台时脚本可能永远不返回，
    /// 引擎那头的调用不能跟着挂死，所以到点就先回一个错误；脚本之后的结果丢掉。
    private func run(
        _ body: String,
        arguments: [String: Any] = [:],
        in world: WKContentWorld? = nil,
        timeout: TimeInterval
    ) async throws -> Any? {
        let world = world ?? Self.agentWorld
        let once = Once()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                guard once.claim() else { return }
                switch result {
                case .success(let value): continuation.resume(returning: value is NSNull ? nil : value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard once.claim() else { return }
                continuation.resume(throwing: BrowserAgentError(
                    "The page did not answer within \(Int(timeout)) seconds. It may be busy, or the app may be in the background."))
            }
        }
    }

    private func unreadable(_ error: Error) -> String {
        let info = (error as NSError).userInfo
        if let message = info["WKJavaScriptExceptionMessage"] as? String, message.contains("__dshBrowser") {
            return "The page is not ready to be read (it may still be loading, or it is not an HTML page). Try `read` again in a moment."
        }
        return "The page could not be read: \(info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)"
    }
}

/// 两条路谁先到谁说了算，另一条什么都不做。
@MainActor
private final class Once {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

extension BrowserPage.Refusal {
    /// 给模型看的说法，和给用户看的 `message` 内容一样。
    var agentMessage: String {
        switch self {
        case .empty: "open needs a URL."
        case .invalid: "That URL is not valid, or it is too long."
        case .credentials: "URLs with a user name or password in them are not opened."
        case .applicationOrigin: "That address is this app's own engine; it cannot be opened in the browser."
        case .unsupportedScheme: "Only http and https pages can be opened. For a local file, start a server and open it on localhost."
        }
    }
}
