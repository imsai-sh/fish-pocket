import SwiftUI

/// The bottom of 设置: the WeChat group's QR code, loaded from the website (`AppLinks.wechatGroupCode`)
/// each time 设置 opens, since the code expires every 7 days and the site swaps it in place. The
/// site serves it with `max-age=0, must-revalidate`, so an unchanged picture comes from the cache.
/// A code on this phone's own screen can't be scanned with it, so the picture saves to the album
/// (button or long press), where WeChat's 扫一扫 can read it.
struct WeChatGroupSection: View {
    @Environment(AppModel.self) private var app
    @State private var phase = Phase.loading
    @State private var saving = false

    private enum Phase {
        case loading, loaded(UIImage), failed
    }

    var body: some View {
        Section {
            VStack(spacing: 14) {
                code
                if case .loaded(let image) = phase {
                    Button { save(image) } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.capsule(.secondary, height: 40))
                        .fixedSize()
                        .disabled(saving)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } header: {
            Text("微信交流群")
        } footer: {
            Text("微信扫码加入交流群。在这台手机上看的话，先保存到相册，再用微信「扫一扫」从相册里识别。")
        }
        .task { await load() }
    }

    /// The site's picture is 617 × 710: the group's name over the code, the expiry date under it.
    private static let width: CGFloat = 220
    private static let height: CGFloat = width * 710 / 617

    @ViewBuilder
    private var code: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(width: Self.width, height: Self.height)
        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "qrcode").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("二维码加载失败").font(.subheadline).foregroundStyle(.secondary)
                Button("重试") { Task { await load() } }
                    .buttonStyle(.capsule(.secondary, height: 36))
                    .fixedSize()
            }
            .frame(width: Self.width, height: Self.height)
        case .loaded(let image):
            // The picture is black on white whatever the appearance: scanners need the light ground.
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: Self.width)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contextMenu {
                    Button { save(image) } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
                    let picture = Image(uiImage: image)
                    ShareLink(item: picture, preview: SharePreview("Fish Pocket", image: picture)) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
                .accessibilityLabel(Text("Fish Pocket 微信交流群二维码"))
        }
    }

    /// Keeps a picture already shown when the reload fails (the list re-runs this on scrolling back).
    private func load() async {
        if case .failed = phase { phase = .loading }
        var request = URLRequest(url: AppLinks.wechatGroupCode)
        request.cachePolicy = .reloadRevalidatingCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            phase = .loaded(image)
        } catch {
            guard !Task.isCancelled else { return }
            if case .loaded = phase { return }
            phase = .failed
        }
    }

    private func save(_ image: UIImage) {
        saving = true
        Task {
            defer { saving = false }
            await PhotoAlbum.add(image, app: app)
        }
    }
}
