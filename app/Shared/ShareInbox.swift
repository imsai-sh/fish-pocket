import Foundation

/// What other apps share to Fish Pocket, on its way from the share extension (app/ShareExtension)
/// to a composer. The extension copies what it was given into a folder of the App Group
/// container, writes where it goes, and opens `dsh://share/<id>`; the app takes the folder and
/// puts its text and files in that composer, where they wait to be sent.
///
/// A delivery the link did not bring over (the system would not open the app) is taken the
/// next time the app comes to the front, as long as it is recent.
enum ShareInbox {
    /// Where a delivery goes.
    enum Target: Codable, Hashable {
        /// A new conversation in the current workspace.
        case newConversation
        /// A Bot's own chat, by the Bot's id.
        case bot(String)
        /// A group chat, by the group's id.
        case room(String)
    }

    struct Delivery: Codable {
        var target: Target
        /// Text and links, one per paragraph.
        var text: String?
        /// File names in the delivery's folder.
        var files: [String]
        var createdAt: Date
    }

    /// A delivery the app took: its folder now belongs to the app, and goes once the composer has the files.
    struct Taken {
        var target: Target
        var text: String?
        var files: [URL]
        var folder: URL
    }

    /// Past this, a delivery that never reached the app is dropped rather than opened unasked.
    static let freshFor: TimeInterval = 30 * 60

    private static let manifest = "delivery.json"

    /// `DshAppGroup` in Info.plist (`DSH_APP_GROUP` in project.yml).
    static var groupId: String? { Bundle.main.object(forInfoDictionaryKey: "DshAppGroup") as? String }

    /// `Share/` in the App Group container: `inbox/<id>/` and the targets the app last listed.
    static var root: URL? {
        guard let groupId, let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else { return nil }
        return container.appending(path: "Share", directoryHint: .isDirectory)
    }

    private static var inbox: URL? { root?.appending(path: "inbox", directoryHint: .isDirectory) }

    // MARK: Extension

    /// A new, empty delivery folder for the extension to copy files into.
    static func newFolder() throws -> (id: String, folder: URL) {
        guard let inbox else { throw CocoaError(.fileNoSuchFile) }
        let id = UUID().uuidString
        let folder = inbox.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (id, folder)
    }

    /// Seal a delivery: written last, so the app never takes a folder still being filled.
    static func seal(_ id: String, delivery: Delivery) throws {
        guard let inbox else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(delivery)
        try data.write(to: inbox.appending(path: "\(id)/\(manifest)"), options: .atomic)
    }

    /// Drop a delivery the extension gave up on.
    static func discard(_ id: String) {
        guard let inbox else { return }
        try? FileManager.default.removeItem(at: inbox.appending(path: id, directoryHint: .isDirectory))
    }

    // MARK: App

    /// Take a delivery out of the shared container into the app's own temporary folder.
    /// nil when it is gone (already taken) or not sealed.
    static func take(_ id: String) -> Taken? {
        guard let inbox, !id.contains("/") else { return nil }
        let source = inbox.appending(path: id, directoryHint: .isDirectory)
        guard let data = try? Data(contentsOf: source.appending(path: manifest)),
              let delivery = try? JSONDecoder().decode(Delivery.self, from: data) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "shared/\(id)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.moveItem(at: source, to: folder)
        } catch {
            return nil
        }
        let files = delivery.files.map { folder.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        return Taken(target: delivery.target, text: delivery.text, files: files, folder: folder)
    }

    /// Sealed deliveries still waiting, newest first; stale ones and folders never sealed are cleared away.
    static func waiting(now: Date = .now) -> [String] {
        guard let inbox, let ids = try? FileManager.default.contentsOfDirectory(atPath: inbox.path) else { return [] }
        var fresh: [(String, Date)] = []
        for id in ids {
            let folder = inbox.appending(path: id, directoryHint: .isDirectory)
            if let data = try? Data(contentsOf: folder.appending(path: manifest)),
               let delivery = try? JSONDecoder().decode(Delivery.self, from: data) {
                if now.timeIntervalSince(delivery.createdAt) < freshFor { fresh.append((id, delivery.createdAt)); continue }
            } else if let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                      now.timeIntervalSince(created) < freshFor {
                // Still being filled by the extension.
                continue
            }
            try? FileManager.default.removeItem(at: folder)
        }
        return fresh.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// The Bots and group chats the share extension offers, as the app last listed them: written
/// by the app (`ShareTargetsWriter`), each with its avatar drawn into `avatars/` next to it.
/// Only names and pictures go here, no messages.
struct ShareTargets: Codable, Equatable {
    struct Bot: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var role: String
    }

    struct Room: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var memberCount: Int
    }

    var bots: [Bot]
    var rooms: [Room]

    init(bots: [Bot], rooms: [Room]) {
        self.bots = bots
        self.rooms = rooms
    }

    /// A file an older app wrote has no groups.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bots = try container.decode([Bot].self, forKey: .bots)
        rooms = try container.decodeIfPresent([Room].self, forKey: .rooms) ?? []
    }

    static let empty = ShareTargets(bots: [], rooms: [])

    private static var fileURL: URL? { ShareInbox.root?.appending(path: "targets.json") }
    static var avatarFolder: URL? { ShareInbox.root?.appending(path: "avatars", directoryHint: .isDirectory) }

    static func avatarURL(of id: String) -> URL? { avatar(named: "bot-\(id)") }
    static func avatarURL(ofRoom id: String, dark: Bool) -> URL? { avatar(named: "room-\(id)\(dark ? "-dark" : "")") }

    private static func avatar(named name: String) -> URL? {
        avatarFolder?.appending(path: "\(name.replacingOccurrences(of: "/", with: "_")).png")
    }

    static func read() -> ShareTargets {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let targets = try? JSONDecoder().decode(ShareTargets.self, from: data) else { return .empty }
        return targets
    }

    func write() {
        guard let fileURL = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
