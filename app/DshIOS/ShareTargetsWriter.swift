import Observation
import SwiftUI

/// Keeps the share extension's Bots and group chats (`ShareTargets`) in step with the team:
/// the Bot page's order, hidden ones left out, each with its avatar drawn as the app draws it.
/// Written shortly after the list changes; an avatar is drawn again only when its look changed.
/// While the team is still loading nothing is written, so the last list stays.
@MainActor
final class ShareTargetsWriter {
    static let shared = ShareTargetsWriter()

    private static let debounce = Duration.seconds(1)
    /// The avatar's size in the extension's rows, in points.
    private static let avatarSize: CGFloat = 36

    private weak var app: AppModel?
    private var written: ShareTargets?
    /// The look each drawn avatar was drawn from, by file name.
    private var drawn: [String: String] = [:]
    private var pendingWrite: Task<Void, Never>?

    private init() {}

    func attach(_ app: AppModel) {
        self.app = app
        observe()
    }

    private func observe() {
        guard let app else { return }
        let listed = withObservationTracking { Self.listed(in: app) } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        guard let listed else { return }
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.write(bots: listed.bots, rooms: listed.rooms)
        }
    }

    /// nil while it is not known yet: the engine or the team is still loading.
    private static func listed(in app: AppModel) -> (bots: [BotInfo], rooms: [RoomInfo])? {
        let team = app.botTeam
        switch team.status {
        case .ready:
            guard !team.team.isNull else { return nil }
            return (team.bots.filter { !$0.hidden && !$0.sessionId.isEmpty }.sorted(by: team.listOrder),
                    team.rooms.filter { !$0.hidden && !$0.sessionId.isEmpty }.sorted(by: team.listOrder))
        case .unknown:
            return nil
        default:
            // No Bot plugin: the extension offers 新对话 alone.
            return ([], [])
        }
    }

    private func write(bots: [BotInfo], rooms: [RoomInfo]) {
        guard let app, let folder = ShareTargets.avatarFolder else { return }
        let team = app.botTeam
        let targets = ShareTargets(
            bots: bots.map { ShareTargets.Bot(id: $0.id, name: $0.name, role: $0.role) },
            rooms: rooms.map { ShareTargets.Room(id: $0.id, name: team.name(of: $0), memberCount: $0.members.count) }
        )
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var kept: Set<String> = []
        for bot in bots {
            guard let url = ShareTargets.avatarURL(of: bot.id) else { continue }
            kept.insert(url.lastPathComponent)
            draw(BotAvatar(bot: bot, size: Self.avatarSize), look: look(of: bot), to: url)
        }
        for room in rooms {
            // RoomAvatar draws the first two members, the second outlined in the page's colour: one per appearance.
            let look = room.members.prefix(2).map { team.bot($0).map(look(of:)) ?? $0 }.joined(separator: "+")
            for scheme in [ColorScheme.light, .dark] {
                guard let url = ShareTargets.avatarURL(ofRoom: room.id, dark: scheme == .dark) else { continue }
                kept.insert(url.lastPathComponent)
                draw(RoomAvatar(room: room, size: Self.avatarSize).environment(\.colorScheme, scheme), look: look, to: url)
            }
        }
        // Avatars of Bots and groups no longer listed.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !kept.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
            drawn[name] = nil
        }
        guard targets != written else { return }
        // Bots and groups no longer listed (gone or hidden) leave the share sheet's top row too.
        let before = written ?? ShareTargets.read()
        let listedNow = Set(targets.bots.map { ShareInbox.Target.bot($0.id) } + targets.rooms.map { ShareInbox.Target.room($0.id) })
        ShareSuggestions.forget((before.bots.map { ShareInbox.Target.bot($0.id) } + before.rooms.map { ShareInbox.Target.room($0.id) })
            .filter { !listedNow.contains($0) })
        written = targets
        targets.write()
    }

    /// What a Bot's avatar is drawn from: when it changes, the picture is drawn again.
    private func look(of bot: BotInfo) -> String {
        guard let team = app?.botTeam else { return "" }
        return [team.usesAppMark(bot) ? "app" : "", bot.avatarImage.map { String($0.hashValue) } ?? "",
                team.character(of: bot).id, bot.colorKey ?? "", bot.name].joined(separator: "|")
    }

    private func draw(_ avatar: some View, look: String, to url: URL) {
        let name = url.lastPathComponent
        guard let app, drawn[name] != look || !FileManager.default.fileExists(atPath: url.path) else { return }
        let renderer = ImageRenderer(content: avatar.environment(app))
        renderer.scale = 3
        if let data = renderer.uiImage?.pngData() {
            try? data.write(to: url, options: .atomic)
            drawn[name] = look
        }
    }
}
