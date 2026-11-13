import UIKit
import UniformTypeIdentifiers
import WebKit

/// 浏览器在「点、填、读」之外的能力：常驻脚本、控制台和网络记录、带登录态的请求、Cookie、
/// 下载、上传、整页截图和 PDF。动作和参数登记在 `BrowserCatalog`，这里是实现。
///
/// 文件路径都是引擎看到的路径（`/home/dsh/...`），相对路径从发起调用的会话的工作目录算起；
/// 真正读写前经 DshRoot 换成 App 里的真实路径。

// MARK: - 引擎路径

enum EnginePath {
    /// The working directory of a conversation, as the engine sees it.
    @MainActor
    static func workingDirectory(of session: String) -> String {
        EngineConnection.shared.app?.sessions[session]?.cwd ?? "/home/dsh"
    }

    /// An engine path made absolute: a relative one is from `cwd`.
    static func absolute(_ path: String, cwd: String) -> String {
        let joined = path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)
        return (joined as NSString).standardizingPath
    }

    /// Where an engine path is in this app.
    static func real(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard dsh_root_real(path, &buffer, buffer.count) == 0 else {
            throw BrowserAgentError("'\(path)' is not a path this app can reach")
        }
        return String(cString: buffer)
    }

    /// A file not yet there: a name not taken in `directory` (an engine path), its folder made.
    static func fresh(_ name: String, in directory: String) throws -> String {
        let realDirectory = try real(directory)
        try FileManager.default.createDirectory(atPath: realDirectory, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespaces)
        let base = safe.isEmpty ? "download" : safe
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var candidate = base
        var n = 2
        while FileManager.default.fileExists(atPath: (realDirectory as NSString).appendingPathComponent(candidate)) {
            candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            n += 1
        }
        return (directory as NSString).appendingPathComponent(candidate)
    }

    /// The folder files come down into: `downloads` in the working directory.
    @MainActor
    static func downloads(of session: String) -> String {
        (workingDirectory(of: session) as NSString).appendingPathComponent("downloads")
    }

    /// Write `data` at an engine path, making its folder; refuses to replace a folder.
    static func write(_ data: Data, to path: String) throws {
        let target = try real(path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue {
            throw BrowserAgentError("'\(path)' is a folder; give a file path")
        }
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: target))
    }
}

// MARK: - 常驻脚本

struct BrowserScript {
    let id: String
    let name: String?
    let source: String
}

extension BrowserPage {
    /// Everything a tab injects, in order: the page controller (agent world), the desktop viewport
    /// fix (agent world), the console and network recorder (page world), then the agent's own scripts
    /// (page world), so their console output is recorded too. Message handlers are not touched.
    func installScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if let script = Self.controllerScript { controller.addUserScript(script) }
        controller.addUserScript(Self.desktopViewport)
        controller.addUserScript(Self.logScript)
        for script in browser?.keptScripts ?? [] {
            let label = (script.name ?? script.id).replacingOccurrences(of: "'", with: "")
            let source = "(() => {\ntry {\n\(script.source)\n} catch (error) { console.error('[script \(label)]', error); }\n})();"
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
    }
}

/// Kept scripts belong to the conversation's browser: every tab, now and later, runs them.
extension BrowserModel {
    private func installScriptsEverywhere() {
        for page in tabs.compactMap(\.page) { page.installScripts() }
    }

    func agentAddScript(_ source: String, name: String?) -> [String: Any] {
        scriptCount += 1
        let script = BrowserScript(id: "s\(scriptCount)", name: name, source: source)
        keptScripts.append(script)
        installScriptsEverywhere()
        var answer = agentScripts()
        answer["added"] = script.id
        answer["note"] = "It runs from the next page load; `reload` to apply it to this page."
        return answer
    }

    func agentScripts() -> [String: Any] {
        ["scripts": keptScripts.map { script -> [String: Any] in
            ["id": script.id, "name": script.name ?? NSNull(), "characters": script.source.count]
        }]
    }

    func agentRemoveScript(_ id: String) throws -> [String: Any] {
        if id == "all" {
            keptScripts.removeAll()
        } else {
            guard keptScripts.contains(where: { $0.id == id }) else {
                throw BrowserAgentError("There is no kept script '\(id)'. `scripts` lists them.")
            }
            keptScripts.removeAll { $0.id == id }
        }
        installScriptsEverywhere()
        return agentScripts()
    }
}

// MARK: - 控制台和网络记录

extension BrowserPage {
    /// Wraps the page's console, its uncaught errors, `fetch` and `XMLHttpRequest`, and posts each to
    /// the app. In the page's own world, because that is where its scripts call them; the page could see
    /// and spoof this, which costs nothing but its own records.
    static let logScript = WKUserScript(source: """
    (() => {
      const handler = globalThis.webkit?.messageHandlers?.dshLog;
      if (!handler) return;
      const post = (entry) => { try { handler.postMessage(entry); } catch {} };
      const show = (value) => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return value.stack || String(value);
        try { const json = JSON.stringify(value); return json === undefined ? String(value) : json; } catch { return String(value); }
      };
      const clip = (text) => text.length > 2000 ? text.slice(0, 2000) + '…' : text;
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        if (typeof original !== 'function') continue;
        console[level] = function (...args) {
          post({ kind: 'console', level, text: clip(args.map(show).join(' ')) });
          return original.apply(this, args);
        };
      }
      addEventListener('error', (event) => {
        const where = event.filename ? ` (${event.filename}:${event.lineno})` : '';
        post({ kind: 'console', level: 'error', text: clip(`Uncaught ${event.error?.stack || event.message}${where}`) });
      });
      addEventListener('unhandledrejection', (event) => {
        post({ kind: 'console', level: 'error', text: clip(`Unhandled rejection: ${show(event.reason)}`) });
      });
      const absolute = (url) => { try { return new URL(url, location.href).href; } catch { return String(url); } };
      const nativeFetch = globalThis.fetch;
      if (typeof nativeFetch === 'function') {
        globalThis.fetch = function (input, init) {
          const started = performance.now();
          const isRequest = typeof Request === 'function' && input instanceof Request;
          const method = String(init?.method || (isRequest ? input.method : 'GET')).toUpperCase();
          const url = absolute(isRequest ? input.url : input);
          const ms = () => Math.round(performance.now() - started);
          return nativeFetch.apply(this, arguments).then((response) => {
            post({ kind: 'network', type: 'fetch', method, url: response.url || url, status: response.status, ms: ms() });
            return response;
          }, (error) => {
            post({ kind: 'network', type: 'fetch', method, url, error: String(error), ms: ms() });
            throw error;
          });
        };
      }
      const requests = new WeakMap();
      const open = XMLHttpRequest.prototype.open;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        requests.set(this, { method: String(method).toUpperCase(), url: absolute(url) });
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        const request = requests.get(this);
        const started = performance.now();
        if (request) {
          this.addEventListener('loadend', () => {
            const entry = { kind: 'network', type: 'xhr', method: request.method, url: this.responseURL || request.url,
                            status: this.status, ms: Math.round(performance.now() - started) };
            if (this.status === 0) entry.error = 'failed, aborted or blocked';
            post(entry);
          });
        }
        return send.apply(this, arguments);
      };
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    private static let logKept = 300

    func record(_ entry: [String: Any]) {
        var entry = entry
        entry["time"] = Self.clock.string(from: Date())
        if entry["kind"] as? String == "network" {
            networkLog.append(entry)
            if networkLog.count > Self.logKept { networkLog.removeFirst(networkLog.count - Self.logKept) }
        } else {
            if entry["page"] == nil, entry["kind"] as? String == "console" { entry["page"] = webView.url?.absoluteString ?? "" }
            consoleLog.append(entry)
            if consoleLog.count > Self.logKept { consoleLog.removeFirst(consoleLog.count - Self.logKept) }
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func agentLogs(kind: String, limit: Int, clear: Bool) -> [String: Any] {
        var entries: [[String: Any]]
        switch kind {
        case "console": entries = consoleLog
        case "network": entries = networkLog
        default:
            entries = (consoleLog + networkLog).sorted { ($0["seq"] as? Int ?? 0) < ($1["seq"] as? Int ?? 0) }
        }
        let total = entries.count
        if entries.count > limit { entries = Array(entries.suffix(limit)) }
        if clear {
            if kind != "network" { consoleLog.removeAll() }
            if kind != "console" { networkLog.removeAll() }
        }
        return [
            "entries": entries.map { $0.filter { $0.key != "seq" } },
            "shown": entries.count,
            "recorded": total,
            "note": "Requests are those the page's scripts made (fetch, XMLHttpRequest), not images or stylesheets. A `page` entry marks a page load.",
        ]
    }

    /// Hears the recorder in the page's world. Weak: the content controller keeps its handlers as long as the web view.
    final class LogListener: NSObject, WKScriptMessageHandler {
        static let name = "dshLog"
        private weak var model: BrowserPage?

        init(_ model: BrowserPage) { self.model = model }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            MainActor.assumeIsolated { model?.receiveLog(body) }
        }
    }

    fileprivate func receiveLog(_ body: [String: Any]) {
        logSeq += 1
        var entry = body
        entry["seq"] = logSeq
        record(entry)
    }

    /// A page load, so the records read in order of the pages they came from.
    func recordPageLoad(_ url: URL?) {
        logSeq += 1
        record(["kind": "page", "url": url?.absoluteString ?? "", "seq": logSeq])
    }
}

// MARK: - 带登录态的请求和 Cookie

extension BrowserPage {
    /// The cookies a browser would send to `url`.
    static func cookies(_ all: [HTTPCookie], for url: URL) -> [HTTPCookie] {
        guard let host = url.host()?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let now = Date()
        return all.filter { cookie in
            var domain = cookie.domain.lowercased()
            let wide = domain.hasPrefix(".")
            if wide { domain.removeFirst() }
            let hostMatches = host == domain || (wide && host.hasSuffix("." + domain))
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = path == cookiePath || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
            let secureMatches = !cookie.isSecure || url.scheme == "https" || host == "localhost"
            let alive = cookie.expiresDate.map { $0 > now } ?? true
            return hostMatches && pathMatches && secureMatches && alive
        }
    }

    private static func describe(_ cookie: HTTPCookie) -> [String: Any] {
        var entry: [String: Any] = [
            "name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
            "secure": cookie.isSecure, "httpOnly": cookie.isHTTPOnly,
        ]
        if let expires = cookie.expiresDate { entry["expires"] = Int(expires.timeIntervalSince1970) }
        if let sameSite = cookie.sameSitePolicy { entry["sameSite"] = sameSite.rawValue }
        return entry
    }

    private func pageURL(_ input: String?) throws -> URL {
        if let input {
            guard let url = URL(string: input), url.host() != nil else { throw BrowserAgentError("'\(input)' is not a full URL") }
            return url
        }
        guard let page else { throw BrowserAgentError("No page is open; pass `url`.") }
        return page
    }

    func agentCookies(url: String?, domain: String?) async throws -> [String: Any] {
        let all = await Self.store.httpCookieStore.allCookies()
        let chosen: [HTTPCookie]
        if let domain {
            let wanted = domain.lowercased()
            chosen = all.filter { $0.domain.lowercased().contains(wanted) }
        } else {
            chosen = Self.cookies(all, for: try pageURL(url))
        }
        return ["cookies": chosen.map(Self.describe), "count": chosen.count]
    }

    func agentSetCookie(_ args: [String: Any]) async throws -> [String: Any] {
        let domain = try (args["domain"] as? String) ?? pageURL(nil).host() ?? ""
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: args["name"] as? String ?? "",
            .value: args["value"] as? String ?? "",
            .domain: domain,
            .path: args["path"] as? String ?? "/",
        ]
        if let expires = (args["expires"] as? NSNumber)?.doubleValue { properties[.expires] = Date(timeIntervalSince1970: expires) }
        if args["secure"] as? Bool == true { properties[.secure] = "TRUE" }
        if args["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        guard let cookie = HTTPCookie(properties: properties) else { throw BrowserAgentError("That cookie could not be made; check its name, value and domain.") }
        await Self.store.httpCookieStore.setCookie(cookie)
        return ["set": Self.describe(cookie)]
    }

    func agentDeleteCookie(name: String, domain: String?) async throws -> [String: Any] {
        let store = Self.store.httpCookieStore
        let all = await store.allCookies()
        let named = all.filter { $0.name == name }
        let doomed: [HTTPCookie]
        if let domain {
            let wanted = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            doomed = named.filter { $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == wanted }
        } else {
            doomed = Self.cookies(named, for: try pageURL(nil))
        }
        for cookie in doomed { await store.deleteCookie(cookie) }
        return ["deleted": doomed.map { ["name": $0.name, "domain": $0.domain, "path": $0.path] }]
    }

    /// The page's user agent, which a request should carry to be taken for this browser.
    private func userAgent() async -> String? {
        if let cachedUserAgent { return cachedUserAgent }
        let agent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
        cachedUserAgent = agent
        return agent
    }

    func agentRequest(_ args: [String: Any], caller: String) async throws -> [String: Any] {
        let input = args["url"] as? String ?? ""
        guard let url = URL(string: input), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else {
            throw BrowserAgentError("request needs a full http or https URL")
        }
        if Self.parse(input, applicationOrigin: origin) == .failure(.applicationOrigin) {
            throw BrowserAgentError(Refusal.applicationOrigin.agentMessage)
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = (args["method"] as? String ?? "GET").uppercased()
        if let body = args["body"] as? String { request.httpBody = Data(body.utf8) }
        let store = Self.store.httpCookieStore
        let sent = Self.cookies(await store.allCookies(), for: url)
        for (name, value) in HTTPCookie.requestHeaderFields(with: sent) { request.setValue(value, forHTTPHeaderField: name) }
        if let agent = await userAgent() { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        for (name, value) in args["headers"] as? [String: String] ?? [:] { request.setValue(value, forHTTPHeaderField: name) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await session.download(for: request)
        } catch {
            throw BrowserAgentError("The request failed: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw BrowserAgentError("The answer was not HTTP.") }

        // What the server set is kept, as the browser itself would.
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { fields, pair in
            if let name = pair.key as? String, let value = pair.value as? String { fields[name] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: http.url ?? url) { await store.setCookie(cookie) }

        var answer: [String: Any] = ["status": http.statusCode, "url": http.url?.absoluteString ?? input, "headers": fields]
        let bytes = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int) ?? 0
        answer["bytes"] = bytes
        let type = (fields.first { $0.key.lowercased() == "content-type" }?.value ?? "").lowercased()
        let textual = type.isEmpty || ["text/", "json", "xml", "javascript", "x-www-form-urlencoded", "html"].contains { type.contains($0) }
        let cwd = EnginePath.workingDirectory(of: caller)

        if let path = args["path"] as? String {
            let target = EnginePath.absolute(path, cwd: cwd)
            try EnginePath.write(try Data(contentsOf: temporary), to: target)
            answer["savedTo"] = target
        } else if textual, bytes <= 2_000_000, let data = try? Data(contentsOf: temporary),
                  let body = String(data: data, encoding: .utf8) {
            let limit = 20000
            answer["body"] = body.count > limit ? String(body.prefix(limit)) : body
            if body.count > limit {
                answer["bodyCut"] = "first \(limit) of \(body.count) characters; pass `path` to save all of it"
            }
        } else {
            let name = http.suggestedFilename ?? url.lastPathComponent
            let target = try EnginePath.fresh(name.isEmpty ? "download" : name, in: EnginePath.downloads(of: caller))
            try EnginePath.write(try Data(contentsOf: temporary), to: target)
            answer["savedTo"] = target
        }
        return answer
    }
}

// MARK: - 下载

struct BrowserDownload {
    var name: String
    var path: String
    var url: String
    var bytes: Int64 = 0
    var state = "downloading"
}

extension BrowserPage: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let source = download.originalRequest?.url?.absoluteString ?? response.url?.absoluteString ?? ""
        guard let browser else { return nil }
        do {
            let path = try EnginePath.fresh(suggestedFilename, in: EnginePath.downloads(of: sessionId))
            browser.downloads.append(BrowserDownload(name: (path as NSString).lastPathComponent, path: path, url: source))
            downloadTasks[ObjectIdentifier(download)] = browser.downloads.count - 1
            return URL(fileURLWithPath: try EnginePath.real(path))
        } catch {
            browser.downloads.append(BrowserDownload(name: suggestedFilename, path: "", url: source, state: "failed: \(error.localizedDescription)"))
            return nil
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let browser, let index = downloadTasks.removeValue(forKey: ObjectIdentifier(download)),
              browser.downloads.indices.contains(index) else { return }
        browser.downloads[index].state = "done"
        browser.downloads[index].bytes = download.progress.completedUnitCount
        if let real = try? EnginePath.real(browser.downloads[index].path),
           let size = try? FileManager.default.attributesOfItem(atPath: real)[.size] as? Int64 {
            browser.downloads[index].bytes = size
        }
        showNotice(String(localized: "已下载「\(browser.downloads[index].name)」到工作区的 downloads 文件夹"))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let browser, let index = downloadTasks.removeValue(forKey: ObjectIdentifier(download)),
              browser.downloads.indices.contains(index) else { return }
        browser.downloads[index].state = "failed: \(error.localizedDescription)"
        showNotice(String(localized: "「\(browser.downloads[index].name)」下载失败"))
    }
}

/// Downloads are listed for the whole browser, whichever tab started them.
extension BrowserModel {
    func agentDownloads() -> [String: Any] {
        ["downloads": downloads.map { item -> [String: Any] in
            ["name": item.name, "path": item.path, "url": item.url, "bytes": item.bytes, "state": item.state]
        }]
    }
}

// MARK: - 上传

extension BrowserPage {
    func agentUpload(index: Int, paths: [String], caller: String) async throws -> [String: Any] {
        attachIfDetached()
        guard webView.url != nil else {
            throw BrowserAgentError("No page is open in this tab yet. Use `open` with a URL first.")
        }
        guard !paths.isEmpty else { throw BrowserAgentError("upload needs at least one path in `paths`") }
        let indexed = (try? await run("return __dshBrowser.indexed()", timeout: 5)) as? Bool ?? false
        guard indexed else {
            throw BrowserAgentError("This page has not been read since it loaded, so its element numbers are unknown. Call `read` first and use the numbers it shows.")
        }
        let cwd = EnginePath.workingDirectory(of: caller)
        var files: [[String: Any]] = []
        var total = 0
        for path in paths {
            let absolute = EnginePath.absolute(path, cwd: cwd)
            guard let data = FileManager.default.contents(atPath: try EnginePath.real(absolute)) else {
                throw BrowserAgentError("'\(path)' could not be read; is it a file?")
            }
            total += data.count
            guard total <= 30_000_000 else { throw BrowserAgentError("The files come to more than 30 MB; upload fewer at a time.") }
            let name = (absolute as NSString).lastPathComponent
            let type = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            files.append(["name": name, "type": type, "data": data.base64EncodedString()])
        }
        let result = try await run("return await __dshBrowser.upload(index, files)", arguments: ["index": index, "files": files], timeout: 30) as? [String: Any]
        let message = result?["message"] as? String ?? "upload done."
        if result?["success"] as? Bool == false { throw BrowserAgentError(message) }
        await settle(navigating: false)
        var state = try await agentRead()
        state["action"] = message
        return state
    }
}

// MARK: - 整页截图和 PDF

extension BrowserPage {
    private func pagePDF() async throws -> Data {
        attachIfDetached()
        guard webView.url != nil else {
            throw BrowserAgentError("No page is open in this tab yet. Use `open` with a URL first.")
        }
        do {
            return try await webView.pdf(configuration: WKPDFConfiguration())
        } catch {
            throw BrowserAgentError("The page could not be captured: \(error.localizedDescription)")
        }
    }

    func agentPDF(path: String?, caller: String) async throws -> [String: Any] {
        let data = try await pagePDF()
        let target: String
        if let path {
            target = EnginePath.absolute(path, cwd: EnginePath.workingDirectory(of: caller))
        } else {
            let title = (webView.title?.isEmpty == false ? webView.title : page?.host()) ?? "page"
            target = try EnginePath.fresh(String(title.prefix(80)) + ".pdf", in: EnginePath.downloads(of: caller))
        }
        try EnginePath.write(data, to: target)
        let pages = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)?.numberOfPages ?? 0
        return ["savedTo": target, "bytes": data.count, "pages": pages, "url": webView.url?.absoluteString ?? ""]
    }

    /// The whole page, top to bottom: WebKit lays it out as one long PDF page, drawn here as a picture. A
    /// very tall page is drawn smaller rather than cut, so the picture stays within what a model takes.
    func agentFullPageScreenshot() async throws -> [String: Any] {
        let data = try await pagePDF()
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let first = document.page(at: 1) else {
            throw BrowserAgentError("The page could not be drawn.")
        }
        let box = first.getBoxRect(.mediaBox)
        let scale = min(2, 12000 / max(box.height, 1), 2400 / max(box.width, 1))
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.drawPDFPage(first)
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else { throw BrowserAgentError("The picture could not be encoded.") }
        return [
            "image": ["data": jpeg.base64EncodedString(), "mediaType": "image/jpeg"],
            "url": webView.url?.absoluteString ?? "",
            "title": webView.title ?? "",
            "fullPage": true,
        ]
    }
}

// MARK: - 系统键盘输入

extension BrowserPage {
    /// The view WebKit draws the page in and takes the keyboard's text through (`UIKeyInput`).
    private var contentView: UIView? {
        webView.scrollView.subviews.first { String(describing: type(of: $0)).hasPrefix("WKContent") }
    }

    /// Text typed as the system keyboard types it: WebKit inserts it into the focused field and the page
    /// gets trusted input events, which a site that ignores a script's `type` still accepts.
    func agentKeys(index: Int?, text: String) async throws -> [String: Any] {
        attachIfDetached()
        guard webView.url != nil else {
            throw BrowserAgentError("No page is open in this tab yet. Use `open` with a URL first.")
        }
        if let index {
            let indexed = (try? await run("return __dshBrowser.indexed()", timeout: 5)) as? Bool ?? false
            guard indexed else {
                throw BrowserAgentError("This page has not been read since it loaded, so its element numbers are unknown. Call `read` first and use the numbers it shows.")
            }
            let focused = try await run("return __dshBrowser.focus(index)", arguments: ["index": index], timeout: 5) as? [String: Any]
            if focused?["success"] as? Bool == false { throw BrowserAgentError(focused?["message"] as? String ?? "That element cannot be focused.") }
        }
        guard let input = contentView as? UIKeyInput, let view = contentView else {
            throw BrowserAgentError("This page has no place for keyboard input right now.")
        }
        view.becomeFirstResponder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.offset > 0 { input.insertText("\n") }
            if !line.element.isEmpty { input.insertText(String(line.element)) }
        }
        await settle(navigating: false)
        var state = try await agentRead()
        state["action"] = "Typed \(text.count) characters with the keyboard."
        return state
    }
}
