import Foundation

/// 浏览器能力的清单：有哪些动作、各自要什么参数、给模型看的说明。
///
/// 这是唯一的一份。引擎按它生成 `browser` 工具（`describe`），原生层按它放行动作
/// （`ios_native.m` 的 `catalog`），参数也按它检查（`check`）。所以加一个浏览器能力，
/// 只要在这里登记一行、在 `BrowserAgent.perform` 里接上实现，别处都不用动。
///
/// 发给模型的话都是英文，和其他能力一致。
enum BrowserCatalog {
    struct Action {
        let name: String
        /// One sentence for the model: what it does and what comes back.
        let does: String
        /// The arguments it reads. An argument it does not read is refused, so a mistake shows.
        var takes: [String] = []
        /// The ones it cannot do without.
        var needs: [String] = []
        /// It answers with a picture, so the engine first checks the model can see one.
        var image = false
    }

    struct Param {
        let name: String
        /// The JSON type the arguments are checked against: string, integer (whole, not negative),
        /// number, boolean, strings (an array of strings) or object (string values).
        let type: String
        let description: String
        var values: [String]? = nil
    }

    static let description = """
    Use the web browser of this conversation, the one the user sees under Workbench → Browser: a real \
    WebKit page with JavaScript, the user's sign-ins and their cookies. Open and read pages, click, type and \
    choose like a person, and go beyond a person: run scripts in the page and keep them across page loads, \
    read the page's console and network requests, send requests with the browser's sign-ins and no CORS, \
    read and change cookies, download and upload files, capture the whole page as a picture or a PDF. Use it \
    for pages that need JavaScript, a login or several steps, and to check a site you are building (open it \
    on localhost). The browser has tabs, \
    shared with the user: `tabs` lists them (which one is in front, which one you last used); `new_tab`, \
    `select_tab` and `close_tab` change them. Page actions work in the tab you pass as `tab`, or else the one \
    you last used, so a link the user opens in a new tab does not move you; to pick up a page the user \
    opened, `select_tab` it. For a plain page whose text is all you need, fetching it is cheaper. `open` and every \
    page action return the page again: its URL and title, then its text with every element you can act on \
    numbered like [3]. Pass that number as `index`; numbers change whenever the page does, so always use the \
    ones from the latest result. File paths are in your workspace; a relative one is from the conversation's \
    working directory. Sites see a phone and usually send their mobile version; `desktop: true` with `open` \
    or `reload` asks for the desktop (PC) version, and the choice stays with that site. Sign-ins are kept \
    across app launches. The user can watch and take over at any time. Never type a password, card number or \
    other secret into a page — ask the user to do that part in the workbench. What you read with `cookies` \
    or `request` can include sign-in tokens: use them for the task, never repeat them in your reply.
    """

    static let actions: [Action] = [
        Action(name: "open", does: "open a URL and return the page.", takes: ["tab", "url", "desktop"], needs: ["url"]),
        Action(name: "read", does: "return the current page again.", takes: ["tab"]),
        Action(name: "click", does: "click a numbered element.", takes: ["tab", "index"], needs: ["index"]),
        Action(name: "type", does: "replace what a numbered field holds with `text`.", takes: ["tab", "index", "text"], needs: ["index", "text"]),
        Action(name: "select", does: "choose an option of a numbered menu by its visible text.", takes: ["tab", "index", "option"], needs: ["index", "option"]),
        Action(name: "scroll", does: "scroll the page, or a numbered scrollable element.", takes: ["tab", "direction", "pages", "index"]),
        Action(name: "back", does: "go back a page.", takes: ["tab"]),
        Action(name: "forward", does: "go forward a page.", takes: ["tab"]),
        Action(name: "reload", does: "load the page again; with `desktop`, as the desktop or the mobile version.", takes: ["tab", "desktop"]),
        Action(name: "evaluate", does: "run `script` once in the page, with its globals, and return what it returns as JSON.", takes: ["tab", "script"], needs: ["script"]),
        Action(name: "screenshot", does: "show what is on screen as a picture, or the whole page with `fullPage`. For layout, images and charts; use `read` for text.", takes: ["tab", "fullPage"], image: true),
        Action(name: "pdf", does: "save the whole page as a PDF file and return its path.", takes: ["tab", "path"]),
        Action(name: "addScript", does: "keep `script` in this browser: it runs in the page before the site's own scripts on every page load from now on (`reload` to apply it to the current page), until removed or the app restarts. For intercepting or rewriting the site's requests, or preparing its environment.", takes: ["script", "name"], needs: ["script"]),
        Action(name: "scripts", does: "list the kept scripts."),
        Action(name: "removeScript", does: "stop running a kept script; `id` from `addScript` or `scripts`, or \"all\".", takes: ["id"], needs: ["id"]),
        Action(name: "logs", does: "what the pages wrote to the console, their uncaught errors, and the requests their scripts made (fetch and XMLHttpRequest: method, URL, status, time), oldest first. Recorded all the time, the last few hundred of each.", takes: ["tab", "kind", "limit", "clear"]),
        Action(name: "request", does: "send an HTTP request as this browser: its cookies and user agent, no CORS. Returns status, headers and the body as text, or saves the body to `path` (a binary body is saved to the downloads folder when no path is given). Cookies the response sets are kept.", takes: ["tab", "url", "method", "headers", "body", "path"], needs: ["url"]),
        Action(name: "cookies", does: "list the cookies sent to `url` (the current page when left out), HttpOnly ones included, or every cookie whose domain contains `domain`.", takes: ["tab", "url", "domain"]),
        Action(name: "setCookie", does: "set a cookie: `name`, `value`, and `domain` (the current page's host when left out), `path`, `expires` (Unix seconds), `secure`, `httpOnly`.", takes: ["tab", "name", "value", "domain", "path", "expires", "secure", "httpOnly"], needs: ["name", "value"]),
        Action(name: "deleteCookie", does: "delete cookies named `name`, on `domain` or wherever they are sent to the current page.", takes: ["tab", "name", "domain"], needs: ["name"]),
        Action(name: "downloads", does: "list the files this browser downloaded, by you or the user, with their paths. A link or response the page cannot show is downloaded to the downloads folder of the working directory."),
        Action(name: "keys", does: "type `text` with the system keyboard into a numbered field (or the focused one): the page gets the same input as from the user's own typing, for a site that ignores `type`. A newline presses Return.", takes: ["tab", "index", "text"], needs: ["text"]),
        Action(name: "tabs", does: "list the tabs: their ids (such as t2), titles and addresses, which one is in front (what the user sees) and which one you last used."),
        Action(name: "new_tab", does: "open a new tab in front, with `url` loaded if given, and work in it from now on.", takes: ["url", "desktop"]),
        Action(name: "select_tab", does: "bring tab `tab` to the front and work in it from now on; returns its page.", takes: ["tab"], needs: ["tab"]),
        Action(name: "close_tab", does: "close tab `tab`; the last one closed leaves a blank tab.", takes: ["tab"], needs: ["tab"]),
        Action(name: "upload", does: "put workspace files into a numbered file field (or the field a numbered button or label opens), as if the user picked them; no picker appears.", takes: ["tab", "index", "paths"], needs: ["index", "paths"]),
    ]

    static let params: [Param] = [
        Param(name: "url", type: "string", description: "open, new_tab: the address, where a bare host means https and localhost means http; request: the full URL; cookies: whose cookies"),
        Param(name: "desktop", type: "boolean", description: "open, new_tab, reload: true for the site's desktop version, false for its mobile one; remembered for that site. Leave it out to keep the site's current choice"),
        Param(name: "index", type: "integer", description: "the element's number from the latest result; scroll: optionally the scrollable element to scroll inside"),
        Param(name: "text", type: "string", description: "type: what to put in the field, replacing what is there; keys: what to type at the cursor"),
        Param(name: "option", type: "string", description: "select: the visible text of the option to choose"),
        Param(name: "direction", type: "string", description: "scroll: which way; defaults to down", values: ["down", "up"]),
        Param(name: "pages", type: "number", description: "scroll: how many screens; defaults to 1"),
        Param(name: "script", type: "string", description: "evaluate: the body of an async function run in the page, with its globals; `return` a JSON-serialisable value to see it. addScript: plain JavaScript run in the page at the start of every load"),
        Param(name: "fullPage", type: "boolean", description: "screenshot: the whole page rather than what is on screen"),
        Param(name: "path", type: "string", description: "pdf, request: where to save the file; defaults to the downloads folder of the working directory"),
        Param(name: "name", type: "string", description: "addScript: a name to know the script by; setCookie, deleteCookie: the cookie's name"),
        Param(name: "id", type: "string", description: "removeScript: the script's id, or \"all\""),
        Param(name: "kind", type: "string", description: "logs: which records; defaults to all", values: ["all", "console", "network"]),
        Param(name: "limit", type: "integer", description: "logs: how many of the newest records; defaults to 100"),
        Param(name: "clear", type: "boolean", description: "logs: forget the records after returning them"),
        Param(name: "method", type: "string", description: "request: the HTTP method; defaults to GET"),
        Param(name: "headers", type: "object", description: "request: extra headers, name to value; they replace the browser's own"),
        Param(name: "body", type: "string", description: "request: the body to send, as text (JSON, a form, …)"),
        Param(name: "domain", type: "string", description: "cookies: list every cookie whose domain contains this; setCookie, deleteCookie: the cookie's domain"),
        Param(name: "value", type: "string", description: "setCookie: the cookie's value"),
        Param(name: "expires", type: "number", description: "setCookie: when it expires, in Unix seconds; a session cookie when left out"),
        Param(name: "secure", type: "boolean", description: "setCookie: only sent over https"),
        Param(name: "httpOnly", type: "boolean", description: "setCookie: hidden from the page's scripts"),
        Param(name: "paths", type: "strings", description: "upload: the files to put in the field"),
        Param(name: "tab", type: "string", description: "select_tab, close_tab: which tab, by its id from `tabs`. A page action: the tab to work in; leave it out for the one you last used"),
    ]

    /// The catalog as the dispatcher and the engine read it. Built once; the same object every time.
    static let dictionary: NSDictionary = [
        "description": description,
        "actions": actions.map { action -> [String: Any] in
            ["name": action.name, "does": action.does, "takes": action.takes, "needs": action.needs, "image": action.image]
        },
        "params": params.map { param -> [String: Any] in ["name": param.name, "schema": schema(param)] },
    ]

    /// The engine's schema for one argument (`@deepseek-ai/dsh-tools`' DSL).
    private static func schema(_ param: Param) -> [String: Any] {
        var schema: [String: Any] = ["description": param.description]
        switch param.type {
        case "strings": schema["type"] = "array"; schema["items"] = ["type": "string"]
        case "object": schema["type"] = "object"; schema["additionalProperties"] = true
        default: schema["type"] = param.type
        }
        if let values = param.values { schema["enum"] = values }
        return schema
    }

    // MARK: 检查参数

    /// The arguments an operation was called with, checked against its entry: nothing it does not read,
    /// nothing it needs left out, every value of its type. The engine's own schema stops most of this
    /// first; this is for every other caller, and for an argument a model slipped past it.
    static func check(_ op: String, _ args: [String: Any]) throws {
        guard let action = actions.first(where: { $0.name == op }) else {
            throw BrowserAgentError("browser has no operation '\(op)'")
        }
        for name in action.needs where args[name] == nil || args[name] is NSNull {
            throw BrowserAgentError("\(op) needs '\(name)'")
        }
        for (name, value) in args where name != "session" && !(value is NSNull) {
            guard action.takes.contains(name) else {
                let users = actions.filter { $0.takes.contains(name) }.map(\.name)
                throw BrowserAgentError(users.isEmpty
                    ? "browser has no argument '\(name)'"
                    : "'\(name)' goes with \(users.joined(separator: ", ")), not \(op)")
            }
            guard let param = params.first(where: { $0.name == name }) else { continue }
            if let problem = mismatch(value, param) { throw BrowserAgentError("\(op): '\(name)' \(problem)") }
        }
    }

    private static func mismatch(_ value: Any, _ param: Param) -> String? {
        let isBool = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch param.type {
        case "string":
            guard let string = value as? String else { return "must be a string" }
            if let values = param.values, !values.contains(string) { return "must be one of \(values.joined(separator: ", "))" }
        case "integer":
            // 3.0 from a model counts.
            guard let number = value as? NSNumber, !isBool, number.doubleValue >= 0,
                  number.doubleValue == number.doubleValue.rounded() else { return "must be a whole number, 0 or more" }
        case "number":
            guard value is NSNumber, !isBool else { return "must be a number" }
        case "boolean":
            guard isBool else { return "must be true or false" }
        case "strings":
            guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else { return "must be a list of strings" }
        case "object":
            guard let object = value as? [String: Any], object.values.allSatisfy({ $0 is String }) else {
                return "must be an object of strings"
            }
        default: break
        }
        return nil
    }
}
