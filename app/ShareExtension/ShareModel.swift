import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

/// What was shared, copied into a delivery folder of `ShareInbox` as soon as the sheet
/// opens, so that picking where it goes is instant. Cancelling drops the folder.
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case reading
        case ready
        /// Nothing in what was shared could be read.
        case empty
        /// Sealed, but the app could not be opened from here: it takes it when opened.
        case waitingForApp
    }

    private(set) var phase = Phase.reading
    private(set) var texts: [String] = []
    /// File names in the delivery folder.
    private(set) var files: [String] = []
    private(set) var imageCount = 0
    /// The first image, small.
    private(set) var thumbnail: UIImage?
    let targets = ShareTargets.read()

    @ObservationIgnored var finish: () -> Void = {}
    @ObservationIgnored var cancel: () -> Void = {}
    @ObservationIgnored var openApp: (URL) -> Bool = { _ in false }
    @ObservationIgnored private var delivery: (id: String, folder: URL)?

    func load(_ providers: [NSItemProvider]) {
        Task {
            guard let delivery = try? ShareInbox.newFolder() else {
                phase = .empty
                return
            }
            self.delivery = delivery
            for provider in providers {
                switch await Self.read(provider, into: delivery.folder) {
                case .text(let text)?:
                    if !texts.contains(text) { texts.append(text) }
                case .file(let name)?:
                    files.append(name)
                    let url = delivery.folder.appending(path: name)
                    if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                        imageCount += 1
                        if thumbnail == nil { thumbnail = Self.thumbnail(of: url) }
                    }
                case nil:
                    break
                }
            }
            phase = texts.isEmpty && files.isEmpty ? .empty : .ready
        }
    }

    func send(to target: ShareInbox.Target) {
        guard phase == .ready, let delivery else { return }
        let text = texts.joined(separator: "\n\n")
        do {
            try ShareInbox.seal(delivery.id, delivery: .init(target: target, text: text.isEmpty ? nil : text, files: files, createdAt: .now))
        } catch {
            phase = .empty
            return
        }
        if openApp(DshLink.share(delivery.id).url) {
            finish()
        } else {
            phase = .waitingForApp
        }
    }

    func dismiss() {
        if phase != .waitingForApp, let delivery { ShareInbox.discard(delivery.id) }
        if phase == .waitingForApp { finish() } else { cancel() }
    }

    /// What one item is, read: a link or text as text, anything else copied in as a file.
    private enum Piece { case text(String), file(String) }

    private nonisolated static func read(_ provider: NSItemProvider, into folder: URL) async -> Piece? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        // A link: a web page as text; a file's URL (the Files app) as that file.
        if types.contains(where: { $0.conforms(to: .url) }),
           let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            if let url {
                if !url.isFileURL { return .text(url.absoluteString) }
                if let name = copy(url, named: url.lastPathComponent, into: folder) { return .file(name) }
            }
        }
        // Text alone (Notes, a selection): not a file of text.
        if !types.isEmpty, types.allSatisfy({ $0.conforms(to: .text) && !$0.conforms(to: .fileURL) }),
           let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
            if let text = (item as? String) ?? (item as? Data).flatMap({ String(data: $0, encoding: .utf8) }) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .text(trimmed)
            }
        }
        // A file's bytes, in the most specific type it offers.
        if let type = types.first(where: { $0.conforms(to: .data) || $0.conforms(to: .package) }),
           let name = await copyRepresentation(of: provider, type: type, into: folder) {
            return .file(name)
        }
        // An image only as an object (a screenshot from the markup editor).
        if types.contains(where: { $0.conforms(to: .image) }),
           let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) {
            let data = (item as? UIImage)?.pngData() ?? (item as? Data)
            if let data, let name = write(data, named: "\(provider.suggestedName ?? String(localized: "图片")).png", into: folder) {
                return .file(name)
            }
        }
        return nil
    }

    private nonisolated static func copyRepresentation(of provider: NSItemProvider, type: UTType, into folder: URL) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // The file is gone once this returns: copied now.
                guard let url else { return continuation.resume(returning: nil) }
                var name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() { name += ".\(ext)" }
                continuation.resume(returning: copy(url, named: name, into: folder))
            }
        }
    }

    private nonisolated static func copy(_ url: URL, named name: String, into folder: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let target = unique(name, in: folder)
        guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return nil }
        return target.lastPathComponent
    }

    private nonisolated static func write(_ data: Data, named name: String, into folder: URL) -> String? {
        let target = unique(name, in: folder)
        guard (try? data.write(to: target)) != nil else { return nil }
        return target.lastPathComponent
    }

    /// `name`, or `name 2`, `name 3`… when two shared files share a name.
    private nonisolated static func unique(_ name: String, in folder: URL) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-")
        let safe = clean.isEmpty || clean.hasPrefix(".") ? "file" + clean : clean
        var candidate = folder.appending(path: safe)
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Read small, without decoding the whole picture: an extension has little memory.
    private static func thumbnail(of url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}
