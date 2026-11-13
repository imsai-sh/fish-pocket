import SwiftUI
import UIKit

/// The small site icon drawn before a web link in a reply, as chat apps do: the site's own
/// favicon on a white tile, or a globe while there is none. Fetched from the linked site itself,
/// once per host while the app runs; a local address is never asked.
@MainActor
@Observable
final class LinkIcons {
    static let shared = LinkIcons()

    /// Tiles drawn, by host.
    private var tiles: [String: UIImage] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    /// The tile for the link's site, or nil while there is none (yet). Reading it in a view's
    /// body redraws the view once the icon arrives.
    func tile(for url: URL) -> UIImage? {
        guard let host = url.host()?.lowercased(), url.scheme == "https" || url.scheme == "http" else { return nil }
        if let tile = tiles[host] { return tile }
        if !asked.contains(host), !Self.isLocal(host) {
            asked.insert(host)
            Task { await load(host: host, scheme: url.scheme ?? "https") }
        }
        return nil
    }

    private func load(host: String, scheme: String) async {
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            guard let url = URL(string: "\(scheme)://\(host)\(path)") else { continue }
            guard let (data, response) = try? await Self.session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 512 * 1024,
                  let image = UIImage(data: data), image.size.width >= 8 else { continue }
            tiles[host] = Self.tile(image)
            return
        }
    }

    /// The icon inset on a white rounded square, the way the reader sees app and site icons.
    private static func tile(_ icon: UIImage) -> UIImage {
        let side: CGFloat = 32
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let frame = CGRect(x: 0, y: 0, width: side, height: side)
            let shape = UIBezierPath(roundedRect: frame, cornerRadius: side * 0.24)
            UIColor.white.setFill()
            shape.fill()
            shape.addClip()
            icon.draw(in: frame.insetBy(dx: side * 0.12, dy: side * 0.12))
            UIColor.black.withAlphaComponent(0.12).setStroke()
            let edge = UIBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: side * 0.24 - 0.5)
            edge.lineWidth = 1
            edge.stroke()
        }
    }

    private static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host == "::1" || host == "[::1]" || host == "0.0.0.0"
    }

    /// What goes before a web link: its site's tile, or a globe, at the size of the text.
    func mark(for url: URL, size: CGFloat) -> Text? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        let side = (size * 1.05).rounded()
        if let tile = tile(for: url), let cgImage = tile.cgImage {
            let image = Image(decorative: cgImage, scale: tile.scale * 32 / side)
            return Text(image).baselineOffset(-side * 0.18) + Text(verbatim: "\u{2009}")
        }
        return Text(Image(systemName: "globe")).font(.system(size: size * 0.85)).foregroundColor(Palette.link)
            + Text(verbatim: "\u{2009}")
    }
}
