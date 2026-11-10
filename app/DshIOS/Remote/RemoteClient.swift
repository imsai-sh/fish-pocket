import Foundation
import Security

/// What an Agents Anywhere server answered instead of a result.
struct RemoteError: LocalizedError, Hashable {
    enum Kind { case offline, unauthorized, notFound, rejected, server, invalid, cancelled }
    let kind: Kind
    var status: Int?
    var code: String?
    let message: String

    var errorDescription: String? { message }

    /// The request certainly changed nothing; anything else may have gone through.
    var definite: Bool { [.offline, .unauthorized, .notFound, .rejected].contains(kind) }
    /// Worth another try by itself, after a pause.
    var transient: Bool { kind == .offline || kind == .server }

    init(kind: Kind, status: Int? = nil, code: String? = nil, message: String) {
        self.kind = kind
        self.status = status
        self.code = code
        self.message = message
    }

    init(_ error: Error) {
        if let error = error as? RemoteError { self = error; return }
        if error is CancellationError { self.init(kind: .cancelled, message: String(localized: "已取消")); return }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: self.init(kind: .cancelled, message: String(localized: "已取消"))
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                self.init(kind: .offline, message: String(localized: "网络已断开"))
            default: self.init(kind: .server, message: String(localized: "与服务器的连接中断"))
            }
            return
        }
        // A WebSocket that drops reports it as a POSIX or CFNetwork error ("Socket is not
        // connected"), not a URLError. Whatever the transport says, it is worth another try.
        self.init(kind: .server, message: String(localized: "与服务器的连接中断"))
    }

    /// `{detail: "…"}` or `{detail: {code, message}}`, as FastAPI writes it.
    static func server(status: Int, body: Data) -> RemoteError {
        let detail = (try? JSONDecoder().decode(JSON.self, from: body))?["detail"] ?? .null
        let message = detail.string ?? detail["message"].string ?? detail.array.first?["msg"].string
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let kind: Kind = switch status {
        case 401, 403: .unauthorized
        case 404, 410: .notFound
        case 408, 425, 429, 500...599: .server
        default: .rejected
        }
        return RemoteError(kind: kind, status: status, code: detail["code"].string, message: message)
    }
}

/// The sign-in an Agents Anywhere account leaves on this phone.
struct RemoteCredentials: Codable, Equatable {
    var server: URL
    var accessToken: String
    /// From a QR sign-in; a password sign-in has none and ends when its token does.
    var refreshToken: String?
    var userId: String
    var name: String
    var email: String?
}

/// The credentials, in the keychain: this device only, readable once it has been unlocked.
enum RemoteKeychain {
    private static let service = "com.wsw.dsh-ios.remote-control"
    private static let account = "credentials"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> RemoteCredentials? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(RemoteCredentials.self, from: data)
    }

    static func save(_ credentials: RemoteCredentials?) {
        SecItemDelete(query as CFDictionary)
        guard let credentials, let data = try? JSONEncoder().encode(credentials) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// A file to send along with a message.
struct RemoteUpload: Hashable {
    var name: String
    var mediaType: String
    var data: Data
}

/// Requests to one Agents Anywhere server under `/api/v2`, signed with the account's token.
/// A token the server no longer takes is renewed once (QR sign-ins carry a renewal token) and
/// the request repeated; when that fails too, `expired` tells the store to ask for a new sign-in.
actor RemoteClient {
    let server: URL
    private var credentials: RemoteCredentials?
    private var renewal: Task<String, Error>?
    private let session: URLSession
    /// The credentials changed (renewed), or are gone (nil: the server refused them for good).
    private let changed: @Sendable (RemoteCredentials?) -> Void

    init(server: URL, credentials: RemoteCredentials? = nil, changed: @escaping @Sendable (RemoteCredentials?) -> Void = { _ in }) {
        self.server = Self.normalize(server)
        self.credentials = credentials
        self.changed = changed
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration)
    }

    /// `host[:port]`, with `https://` when no scheme was typed; nil when it is not an address.
    static func serverURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return nil }
        return normalize(url)
    }

    /// The origin alone: the API's path is added per request.
    static func normalize(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url ?? url
    }

    static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? component
    }

    // MARK: Requests

    @discardableResult
    func get(_ path: String, query: [String: String] = [:]) async throws -> JSON {
        try await send("GET", path, query: query)
    }

    @discardableResult
    func post(_ path: String, _ body: JSON? = nil, query: [String: String] = [:], signed: Bool = true) async throws -> JSON {
        try await send("POST", path, query: query, body: body ?? .object([:]), signed: signed)
    }

    @discardableResult
    func patch(_ path: String, _ body: JSON) async throws -> JSON { try await send("PATCH", path, body: body) }

    @discardableResult
    func put(_ path: String, _ body: JSON) async throws -> JSON { try await send("PUT", path, body: body) }

    @discardableResult
    func delete(_ path: String) async throws -> JSON { try await send("DELETE", path) }

    /// `multipart/form-data`, every file under the field `files`.
    func upload(_ path: String, files: [RemoteUpload]) async throws -> JSON {
        let boundary = "FishPocket-\(UUID().uuidString)"
        var body = Data()
        func quoted(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        }
        for file in files {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(quoted(file.name))\"\r\nContent-Type: \(file.mediaType)\r\n\r\n".utf8))
            body.append(file.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return try await perform(signed: true) { token in
            var request = try self.request("POST", path, query: [:])
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
            request.httpBody = body
            return request
        }
    }

    /// The bytes behind a link the server handed out (an attachment), kept to this server.
    func data(at link: String) async throws -> Data {
        guard let url = URL(string: link, relativeTo: server)?.absoluteURL, url.host == server.host, url.scheme == server.scheme else {
            throw RemoteError(kind: .invalid, message: String(localized: "服务器返回的地址无效"))
        }
        let token = try await token()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw RemoteError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        }
        return data
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil, signed: Bool = true) async throws -> JSON {
        let payload = try body.map { try JSONEncoder().encode($0) }
        return try await perform(signed: signed) { token in
            var request = try self.request(method, path, query: query)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let payload {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = payload
            }
            return request
        }
    }

    private func request(_ method: String, _ path: String, query: [String: String]) throws -> URLRequest {
        guard var parts = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            throw RemoteError(kind: .invalid, message: String(localized: "服务器地址无效"))
        }
        parts.percentEncodedPath = "/api/v2" + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { throw RemoteError(kind: .invalid, message: String(localized: "服务器地址无效")) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(signed: Bool, _ build: (String?) throws -> URLRequest) async throws -> JSON {
        var token = signed ? try await self.token() : nil
        for attempt in 0..<2 {
            let (data, response) = try await load(try build(token))
            guard let http = response as? HTTPURLResponse else { throw RemoteError(kind: .invalid, message: String(localized: "服务器没有正常回应")) }
            if http.statusCode == 401, signed, attempt == 0 {
                token = try await renew(replacing: token)
                continue
            }
            guard 200..<300 ~= http.statusCode else { throw RemoteError.server(status: http.statusCode, body: data) }
            if data.isEmpty { return .null }
            guard let value = try? JSONDecoder().decode(JSON.self, from: data) else {
                throw RemoteError(kind: .invalid, status: http.statusCode, message: String(localized: "服务器返回了无法识别的内容"))
            }
            return value
        }
        throw RemoteError(kind: .unauthorized, status: 401, message: String(localized: "登录已失效，请重新登录"))
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) } catch { throw RemoteError(error) }
    }

    // MARK: Token

    private func token() async throws -> String {
        guard let token = credentials?.accessToken, !token.isEmpty else {
            throw RemoteError(kind: .unauthorized, message: String(localized: "尚未登录"))
        }
        return token
    }

    /// One renewal for all the requests that found the token stale together.
    private func renew(replacing stale: String?) async throws -> String {
        if let current = credentials?.accessToken, current != stale { return current }
        if let renewal { return try await renewal.value }
        guard let refresh = credentials?.refreshToken else { return try expire() }
        let task = Task { () throws -> String in
            var request = try self.request("POST", "/auth/mobile-login/refresh", query: [:])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(JSON.object(["refreshToken": .string(refresh)]))
            let (data, response) = try await self.load(request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw RemoteError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
            }
            let value = try JSONDecoder().decode(JSON.self, from: data)
            guard let token = value["accessToken"].string ?? value["auth"]["accessToken"].string else {
                throw RemoteError(kind: .invalid, message: String(localized: "服务器返回了无法识别的内容"))
            }
            return token
        }
        renewal = task
        defer { renewal = nil }
        do {
            let token = try await task.value
            credentials?.accessToken = token
            changed(credentials)
            return token
        } catch let error as RemoteError where error.kind == .unauthorized || error.kind == .rejected || error.kind == .notFound {
            return try expire()
        }
    }

    private func expire() throws -> String {
        credentials = nil
        changed(nil)
        throw RemoteError(kind: .unauthorized, status: 401, message: String(localized: "登录已失效，请重新登录"))
    }

    // MARK: Live updates

    /// The key a frame carries its arrival time under (seconds since 1970).
    static let arrival = "$arrivedAt"

    /// Frames of one of the server's WebSocket channels, each a JSON object. The server sends
    /// something at least every 15 s; 45 s of silence ends the stream so the caller reconnects.
    nonisolated func frames(_ path: String, ticket: String) -> AsyncThrowingStream<JSON, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            guard var parts = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
                continuation.finish(throwing: RemoteError(kind: .invalid, message: String(localized: "服务器地址无效")))
                return
            }
            parts.scheme = parts.scheme == "https" ? "wss" : "ws"
            parts.percentEncodedPath = "/api/v2" + path
            parts.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
            guard let url = parts.url else {
                continuation.finish(throwing: RemoteError(kind: .invalid, message: String(localized: "服务器地址无效")))
                return
            }
            let socket = URLSession.shared.webSocketTask(with: url)
            socket.maximumMessageSize = 32 << 20
            socket.resume()
            let heard = HeardAt()
            let reader = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        heard.touch()
                        let data: Data = switch message {
                        case .data(let data): data
                        case .string(let text): Data(text.utf8)
                        @unknown default: Data()
                        }
                        guard case .object(var frame)? = try? JSONDecoder().decode(JSON.self, from: data) else { continue }
                        if frame["type"]?.string == "keepalive" { continue }
                        // When it arrived, for a reader that has to tell it from what it read since.
                        frame[RemoteClient.arrival] = .number(Date().timeIntervalSince1970)
                        continuation.yield(.object(frame))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: RemoteError(error))
                }
            }
            let watchdog = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    if heard.silence > 45 {
                        continuation.finish(throwing: RemoteError(kind: .server, message: String(localized: "与服务器的连接中断")))
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                watchdog.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    /// A single-use ticket for a WebSocket channel: `sessionId` for one session, nil for the overview.
    func ticket(sessionId: String?) async throws -> String {
        let scope: JSON = sessionId.map { ["sessionId": .string($0), "dashboard": false] } ?? ["dashboard": true]
        let value = try await post("/ws-ticket", ["clientId": .string("fish-pocket-\(UUID().uuidString)"), "scope": scope])
        guard let ticket = value["ticket"].string else {
            throw RemoteError(kind: .invalid, message: String(localized: "服务器返回了无法识别的内容"))
        }
        return ticket
    }
}

/// When a socket last delivered anything, shared by its reader and its watchdog.
private final class HeardAt: @unchecked Sendable {
    private let lock = NSLock()
    private var at = Date()

    func touch() { lock.lock(); at = Date(); lock.unlock() }
    var silence: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(at) }
}
