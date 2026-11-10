import Foundation
import Observation
import UIKit

/// The login a QR code on Agents Anywhere's web or desktop app carries.
struct RemoteLoginCode: Hashable {
    let server: URL
    let userId: String
    let token: String

    /// nil when the scanned text is not such a code.
    init?(scanned text: String) {
        guard let value = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)),
              value["type"].string == "agents-anywhere.mobile-login", value["version"].int == 1,
              let server = value["webUrl"].string.flatMap(RemoteClient.serverURL(from:)),
              let userId = value["userId"].string, let token = value["loginToken"].string else { return nil }
        self.server = server
        self.userId = userId
        self.token = token
    }
}

/// Remote control: the computers of an Agents Anywhere account and the agent sessions on them.
/// The phone is one more client of that account's server (the cloud one or the user's own); it
/// keeps the account's list here and follows it over one WebSocket while the app is in front.
/// Nothing happens, and nothing shows, until the user signs in.
@MainActor
@Observable
final class RemoteStore {
    /// A remote session in the shell's one selection: `remote:<id>` beside the engine's own ids.
    nonisolated static let prefix = "remote:"
    nonisolated static func selection(_ sessionId: String) -> String { prefix + sessionId }
    nonisolated static func sessionId(of selection: String?) -> String? {
        guard let selection, selection.hasPrefix(prefix) else { return nil }
        return String(selection.dropFirst(prefix.count))
    }

    /// Agents Anywhere's own places, for what this app leaves to it.
    enum Links {
        static let site = URL(string: "https://www.agents-anywhere.com")!
        static let download = URL(string: "https://www.agents-anywhere.com/download")!
        static let cloud = URL(string: "https://web.agents-anywhere.com")!
        static let repository = URL(string: "https://github.com/anywhere-labs/Agents-Anywhere")!
        static let app = URL(string: "https://apps.apple.com/app/agents-anywhere/id6787125178")!
    }

    private(set) var account: RemoteCredentials?
    private(set) var devices: [RemoteDevice] = []
    private(set) var projects: [RemoteProject] = []
    private(set) var agents: [RemoteAgent] = []
    private(set) var sessions: [String: RemoteSession] = [:]
    /// What the sidebar draws from, kept ready: sessions in list order (pinned, then most recent),
    /// the archived ones apart, and devices and projects by id. A redraw then sorts and searches nothing.
    private(set) var active: [RemoteSession] = []
    private(set) var archivedSessions: [RemoteSession] = []
    private var deviceIndex: [String: RemoteDevice] = [:]
    private var projectIndex: [String: RemoteProject] = [:]
    /// The list has been read at least once since signing in.
    private(set) var loaded = false
    /// The list is being followed live.
    private(set) var connected = false
    /// Why the list could not be read, while that lasts.
    private(set) var problem: String?
    /// The server ended the sign-in; shown once, then cleared.
    var expired = false

    @ObservationIgnored private(set) var client: RemoteClient?
    @ObservationIgnored private var follow: Task<Void, Never>?
    /// Open conversations by session; a session can be open in more than one window.
    @ObservationIgnored private var open: [String: [Weak]] = [:]
    @ObservationIgnored private var inFront = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private final class Weak {
        weak var model: RemoteSessionModel?
        init(_ model: RemoteSessionModel) { self.model = model }
    }

    var signedIn: Bool { account != nil }

    init() {
        // The whole app, not a window: on iPad one window can leave while another stays.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setInFront(false) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setInFront(true) }
            },
        ]
        guard let saved = RemoteKeychain.load() else { return }
        adopt(saved)
    }

    // MARK: Reading

    func device(_ id: String?) -> RemoteDevice? { id.flatMap { deviceIndex[$0] } }
    func project(_ id: String?) -> RemoteProject? { id.flatMap { projectIndex[$0] } }
    func agents(on deviceId: String) -> [RemoteAgent] { agents.filter { $0.deviceId == deviceId && $0.configured } }

    /// Pinned first, then by the server's own order of recency.
    func listed(archived: Bool = false) -> [RemoteSession] { archived ? archivedSessions : active }

    /// After any change to devices, projects or sessions. Only what differs is assigned:
    /// the server repeats the whole list on every push, and an unchanged one must not redraw anything.
    private func reindex() {
        let deviceIndex = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        if deviceIndex != self.deviceIndex { self.deviceIndex = deviceIndex }
        let projectIndex = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        if projectIndex != self.projectIndex { self.projectIndex = projectIndex }
        let active = sessions.values.filter { !$0.archived }.sorted(by: Self.precedes)
        if active != self.active { self.active = active }
        let archived = sessions.values.filter(\.archived).sorted(by: Self.precedes)
        if archived != archivedSessions { archivedSessions = archived }
    }

    static func precedes(_ lhs: RemoteSession, _ rhs: RemoteSession) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned }
        if lhs.sortAt != rhs.sortAt { return lhs.sortAt > rhs.sortAt }
        return lhs.id > rhs.id
    }

    /// The folder a session runs in, as its project names it.
    func place(of session: RemoteSession) -> String {
        if let project = project(session.projectId) { return project.name }
        if let cwd = session.cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return String(localized: "未分组")
    }

    func deviceName(of session: RemoteSession) -> String { device(session.deviceId)?.name ?? String(localized: "未知设备") }

    // MARK: Signing in and out

    /// Email and password, for a server of the user's own (the cloud one signs in by QR code).
    func signIn(server: URL, email: String, password: String) async throws {
        let probe = RemoteClient(server: server)
        let value = try await probe.post("/auth/login", ["email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines)), "password": .string(password)], signed: false)
        try finish(server: server, auth: value, refreshToken: nil)
    }

    /// Ask the signed-in browser to confirm this phone; returns once it has been asked.
    func requestLogin(_ code: RemoteLoginCode) async throws {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        try await RemoteClient(server: code.server).post("/auth/mobile-login/request", [
            "userId": .string(code.userId), "loginToken": .string(code.token), "deviceName": .string("Fish Pocket · \(device)"),
        ], signed: false)
    }

    /// Wait for the confirmation on the computer, then sign in. Throws when it is refused or runs out.
    func awaitLogin(_ code: RemoteLoginCode) async throws {
        let probe = RemoteClient(server: code.server)
        while true {
            try Task.checkCancellation()
            let status = try await probe.post("/auth/mobile-login/status", ["loginToken": .string(code.token)], signed: false)["status"].string
            switch status {
            case "approved":
                let value = try await probe.post("/auth/mobile-login/exchange", ["userId": .string(code.userId), "loginToken": .string(code.token)], signed: false)
                try finish(server: code.server, auth: value["auth"], refreshToken: value["refreshToken"].string)
                return
            case "pending_web_confirm":
                try await Task.sleep(for: .milliseconds(1500))
            case "rejected":
                throw RemoteError(kind: .rejected, message: String(localized: "电脑上拒绝了这次登录"))
            case "expired":
                throw RemoteError(kind: .rejected, message: String(localized: "二维码已过期，请在电脑上刷新后重新扫描"))
            case "consumed":
                throw RemoteError(kind: .rejected, message: String(localized: "这个二维码已经用过了，请在电脑上刷新后重新扫描"))
            default:
                throw RemoteError(kind: .invalid, message: String(localized: "登录没有完成，请重新扫描"))
            }
        }
    }

    private func finish(server: URL, auth: JSON, refreshToken: String?) throws {
        guard let token = auth["accessToken"].string, let userId = auth["userId"].string else {
            throw RemoteError(kind: .invalid, message: String(localized: "服务器返回了无法识别的内容"))
        }
        let name = auth["displayName"].string.flatMap { $0.isEmpty ? nil : $0 } ?? auth["email"].string ?? String(localized: "已登录")
        let credentials = RemoteCredentials(server: RemoteClient.normalize(server), accessToken: token, refreshToken: refreshToken,
                                            userId: userId, name: name, email: auth["email"].string)
        RemoteKeychain.save(credentials)
        expired = false
        adopt(credentials)
    }

    func signOut() {
        RemoteKeychain.save(nil)
        clear()
    }

    private func adopt(_ credentials: RemoteCredentials) {
        clear()
        account = credentials
        client = RemoteClient(server: credentials.server, credentials: credentials) { [weak self] next in
            Task { @MainActor [weak self] in self?.credentialsChanged(next, server: credentials.server, userId: credentials.userId) }
        }
        startFollowing()
    }

    /// The client renewed its token, or the server refused the sign-in for good.
    private func credentialsChanged(_ next: RemoteCredentials?, server: URL, userId: String) {
        guard account?.server == server, account?.userId == userId else { return }
        if let next {
            account = next
            RemoteKeychain.save(next)
        } else {
            RemoteKeychain.save(nil)
            clear()
            expired = true
        }
    }

    private func clear() {
        follow?.cancel()
        follow = nil
        let models = open.values.flatMap { $0 }.compactMap(\.model)
        open = [:]
        for model in models { model.close() }
        client = nil
        account = nil
        devices = []
        projects = []
        agents = []
        sessions = [:]
        reindex()
        loaded = false
        connected = false
        problem = nil
    }

    // MARK: Following the list

    /// The app came to the front or left it: the list is only followed in front.
    private func setInFront(_ front: Bool) {
        inFront = front
        if front { startFollowing() } else {
            follow?.cancel()
            follow = nil
            connected = false
        }
        for model in open.values.flatMap({ $0 }).compactMap(\.model) { front ? model.resume() : model.suspend() }
    }

    private func startFollowing() {
        guard inFront, follow == nil, let client else { return }
        follow = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                do {
                    try await self?.reload(client)
                    let ticket = try await client.ticket(sessionId: nil)
                    guard let self, !Task.isCancelled else { return }
                    self.connected = true
                    self.problem = nil
                    attempt = 0
                    for try await frame in client.frames("/dashboard/ws", ticket: ticket) {
                        guard frame["type"].string == "dashboard.snapshot" else { continue }
                        // A push carries every session of the account: read it off the main thread.
                        let parsed = await Task.detached(priority: .userInitiated) { Self.parse(frame) }.value
                        guard self.client === client, !Task.isCancelled else { return }
                        self.apply(parsed)
                    }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    let failure = RemoteError(error)
                    if failure.kind == .unauthorized {
                        self.credentialsChanged(nil, server: client.server, userId: self.account?.userId ?? "")
                        return
                    }
                    if failure.kind != .cancelled { self.problem = failure.message }
                }
                guard let self, !Task.isCancelled else { return }
                self.connected = false
                attempt += 1
                try? await Task.sleep(for: .seconds(min(pow(2, Double(attempt - 1)), 15)))
            }
        }
    }

    /// Read the list now (pull to refresh).
    func refresh() async {
        guard let client else { return }
        do {
            try await reload(client)
            problem = nil
        } catch {
            let failure = RemoteError(error)
            if failure.kind != .cancelled { problem = failure.message }
        }
    }

    private func reload(_ client: RemoteClient) async throws {
        async let connectors = client.get("/connectors")
        async let projects = client.get("/projects")
        async let sessions = client.get("/sessions/list")
        let (connectorList, projectList, sessionList) = try await (connectors, projects, sessions)
        let snapshot = JSON.object(["connectors": connectorList["connectors"], "projects": projectList["projects"], "sessions": sessionList["sessions"]])
        let parsed = await Task.detached(priority: .userInitiated) { Self.parse(snapshot) }.value
        guard self.client === client else { return }
        apply(parsed)
    }

    private struct Parsed: Sendable {
        var devices: [RemoteDevice]
        var projects: [RemoteProject]
        /// nil when the reading does not carry them (only the live channel does).
        var agents: [RemoteAgent]?
        var sessions: [RemoteSession]
    }

    nonisolated private static func parse(_ snapshot: JSON) -> Parsed {
        Parsed(
            devices: snapshot["connectors"].array.compactMap(RemoteDevice.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            projects: snapshot["projects"].array.compactMap(RemoteProject.init),
            agents: snapshot["runtimes"].isNull ? nil : snapshot["runtimes"].array.compactMap(RemoteAgent.init),
            sessions: snapshot["sessions"].array.compactMap(RemoteSession.init)
        )
    }

    private func apply(_ parsed: Parsed) {
        if devices != parsed.devices { devices = parsed.devices }
        if projects != parsed.projects { projects = parsed.projects }
        if let agents = parsed.agents, agents != self.agents { self.agents = agents }
        var next: [String: RemoteSession] = [:]
        next.reserveCapacity(parsed.sessions.count)
        for session in parsed.sessions { next[session.id] = merged(sessions[session.id], session) }
        if next != sessions { sessions = next }
        if !loaded { loaded = true }
        reindex()
        for (id, boxes) in open {
            guard let session = next[id] else { continue }
            for box in boxes { box.model?.apply(meta: session) }
        }
    }

    /// The newer of two readings; what has been read stays read.
    private func merged(_ current: RemoteSession?, _ incoming: RemoteSession) -> RemoteSession {
        var value = current.map { $0.updatedSeq > incoming.updatedSeq ? $0 : incoming } ?? incoming
        value.lastReadSeq = max(current?.lastReadSeq ?? 0, incoming.lastReadSeq)
        if value.lastReadSeq >= value.latestTurnEndSeq { value.unread = false }
        return value
    }

    /// A session as a request or a session's own channel just reported it.
    func upsert(_ json: JSON) {
        guard let session = RemoteSession(json) else { return }
        let next = merged(sessions[session.id], session)
        guard next != sessions[session.id] else { return }
        sessions[session.id] = next
        reindex()
    }

    /// The agents of a device, read from it (the live list only carries them once it has pushed).
    func loadAgents(on deviceId: String) async {
        guard let client, let value = try? await client.get("/connectors/\(RemoteClient.encode(deviceId))/runtimes") else { return }
        let fresh = value["runtimes"].array.compactMap(RemoteAgent.init)
        agents = agents.filter { $0.deviceId != deviceId } + fresh
    }

    // MARK: Open sessions

    func register(_ model: RemoteSessionModel) {
        let boxes = (open[model.id] ?? []).filter { $0.model != nil && $0.model !== model }
        open[model.id] = boxes + [Weak(model)]
    }

    func unregister(_ model: RemoteSessionModel) {
        let boxes = (open[model.id] ?? []).filter { $0.model != nil && $0.model !== model }
        open[model.id] = boxes.isEmpty ? nil : boxes
    }

    // MARK: Changes

    /// Run a change; a failure is the message to show.
    private func change(_ work: (RemoteClient) async throws -> Void) async -> String? {
        guard let client else { return String(localized: "尚未登录") }
        do { try await work(client); return nil } catch {
            let failure = RemoteError(error)
            return failure.kind == .cancelled ? nil : failure.message
        }
    }

    func rename(session id: String, to title: String) async -> String? {
        await change { client in
            let value = try await client.patch("/sessions/\(RemoteClient.encode(id))/meta", ["title": .string(title)])
            upsert(value["session"])
        }
    }

    func setPinned(_ id: String, _ pinned: Bool) async -> String? {
        await change { client in
            let value = try await client.patch("/sessions/\(RemoteClient.encode(id))/meta", ["pinned": .bool(pinned)])
            upsert(value["session"])
        }
    }

    func setArchived(_ id: String, _ archived: Bool) async -> String? {
        await change { client in
            let value = try await client.post(archived ? "/sessions/archive" : "/sessions/unarchive", [.string(id)])
            for session in value["sessions"].array { upsert(session) }
        }
    }

    /// The reader has seen the session's last finished turn.
    func markRead(_ id: String) {
        guard let session = sessions[id], session.unread, let client else { return }
        sessions[id]?.unread = false
        sessions[id]?.lastReadSeq = session.latestTurnEndSeq
        reindex()
        Task {
            guard let value = try? await client.post("/sessions/read", [.string(id)]) else { return }
            for session in value["sessions"].array { upsert(session) }
        }
    }

    func rename(device id: String, to name: String) async -> String? {
        await change { client in
            let value = try await client.patch("/connectors/\(RemoteClient.encode(id))", ["name": .string(name)])
            if let device = RemoteDevice(value["connector"]), let index = devices.firstIndex(where: { $0.id == id }) { devices[index] = device }
            reindex()
        }
    }

    /// Takes the device off the account, with its projects and sessions.
    func remove(device id: String) async -> String? {
        await change { client in
            try await client.delete("/connectors/\(RemoteClient.encode(id))")
            devices.removeAll { $0.id == id }
            projects.removeAll { $0.deviceId == id }
            agents.removeAll { $0.deviceId == id }
            sessions = sessions.filter { $0.value.deviceId != id }
            reindex()
        }
    }

    /// The project of a folder on a device, made when the folder has none yet.
    func project(on deviceId: String, path: String) async throws -> RemoteProject {
        guard let client else { throw RemoteError(kind: .unauthorized, message: String(localized: "尚未登录")) }
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        func existing(_ list: [RemoteProject]) -> RemoteProject? {
            list.first { $0.deviceId == deviceId && Self.samePath($0.path, path) }
        }
        if let found = existing(projects) { return found }
        let current = try await client.get("/projects")["projects"].array.compactMap(RemoteProject.init)
        if let found = existing(current) { return found }
        var name = (path as NSString).lastPathComponent
        if name.isEmpty { name = path }
        let taken = Set(current.filter { $0.deviceId == deviceId }.map(\.name))
        var candidate = name, suffix = 2
        while taken.contains(candidate) { candidate = "\(name) \(suffix)"; suffix += 1 }
        let value = try await client.post("/projects", [
            "name": .string(candidate), "connectorId": .string(deviceId), "workspacePath": .string(path), "manuallyCreated": false,
        ])
        guard let project = RemoteProject(value["project"]) else {
            throw RemoteError(kind: .invalid, message: String(localized: "服务器返回了无法识别的内容"))
        }
        projects.removeAll { $0.id == project.id }
        projects.append(project)
        reindex()
        return project
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        func key(_ path: String) -> String {
            var path = path.replacingOccurrences(of: "\\", with: "/")
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        return key(lhs) == key(rhs)
    }
}
