import SwiftUI

/// Mini Apps: the small tools and games the agent made, as icons on a grid set out as a home
/// screen's. The ones the app came with sit apart under 示例, so they read as examples of what to
/// ask for rather than a catalog of ours. The way to a new one is where a conversation's composer
/// is, and looks like it: the request is typed there, on this page, and sending it starts the
/// conversation that makes the app.
struct MiniAppsPage: View {
    @State private var store = MiniAppStore.shared
    @State private var deleting: MiniApp?
    @State private var addingToHome: AddToHomeScreenSheet.Target?
    /// The page's width (the grid's columns and spacing follow from it) and the height it shows
    /// between its bars (the note goes to the foot of that).
    @State private var page: CGSize = .zero
    @Environment(\.scenePhase) private var scenePhase
    /// An iPad or an open Duo: bigger icons, as on its home screen.
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let examples = MiniAppExamples.ids
        let mine = store.apps.filter { !examples.contains($0.id) }
        let samples = store.apps.filter { examples.contains($0.id) }
        let grid = IconGrid(width: page.width, wide: sizeClass == .regular)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !mine.isEmpty {
                    section(String(localized: "我做的"), mine, grid)
                }
                if !samples.isEmpty {
                    section(String(localized: "示例"), samples, grid)
                }
                if store.loaded && store.apps.isEmpty {
                    empty
                }
                // Out of the apps' way: at the foot of the page, just over the bar, and after the
                // last of them once they fill it.
                Spacer(minLength: 0)
                Text("Mini App 只在这台设备上运行，彼此隔离，读不到你的文件和对话，可以联网。")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, grid.gap)
            }
            .frame(maxWidth: .infinity, minHeight: max(0, page.height - 20), alignment: .topLeading)
            .padding(.top, 8)
            .padding(.bottom, 12)
            // The blank between the icons answers a tap too, to put the keyboard away.
            .contentShape(Rectangle())
        }
        // The page's own size, not its content's: a grid laid out for a wider page (a sheet's first
        // pass at the window's width, an iPad turned upright) would hold the content at that width.
        // The size is already what shows between the bars and beside the screen's edges.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { LayoutLoopGuard.tick("MiniAppsPage.size"); page = $0 }
        // As in a conversation: any drag on the page or a tap on it puts the bar's keyboard away.
        // The tap a moment later, so an icon under the finger opens first.
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(TapGesture().onEnded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { dismissKeyboard() }
        })
        .background(Palette.background)
        .tabEdgesSoftened()
        // The ideas are for a first one; once there is one of their own, the bar alone.
        .conversationDock { MiniAppRequestBar(first: mine.isEmpty) }
        .navigationTitle(Self.tabTitle)
        .toolbarTitleDisplayMode(.inline)
        .onAppear { store.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.refresh() } }
        .sheet(item: $addingToHome) { AddToHomeScreenSheet(target: $0) }
        .confirmationDialog("删除「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除 Mini App", role: .destructive) {
                guard let app = deleting else { return }
                Task { await store.delete(app) }
            }
        } message: {
            Text("Mini App 的文件和它保存的数据都会删除，无法恢复。")
        }
    }

    /// The page's title, and its row on 探索 and in the iPad's sidebar before iOS 18.
    static var tabTitle: String {
        String(localized: "tab.apps", defaultValue: "Mini Apps", comment: "Tab and page title: the small tools and games the user had the agent make")
    }

    private func section(_ title: String, _ apps: [MiniApp], _ grid: IconGrid) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // On the first icon's edge, as everything on the page is.
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, grid.gap)
            LazyVGrid(columns: grid.columns, alignment: .leading, spacing: 22) {
                ForEach(apps) { app in
                    Button { open(app) } label: { tile(app, grid) }
                        .buttonStyle(.plain)
                        .contextMenu { menu(app) }
                }
            }
            .padding(.horizontal, grid.gap / 2)
        }
    }

    private func tile(_ app: MiniApp, _ grid: IconGrid) -> some View {
        VStack(spacing: 7) {
            MiniAppIcon(app, size: grid.icon)
            Text(app.name).font(.caption).foregroundStyle(Palette.ink).lineLimit(1)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// No apps at all, not even the examples: what the page is for, over the bar that makes one.
    private var empty: some View {
        VStack(spacing: 6) {
            Text("做一个自己的 Mini App").font(.headline).foregroundStyle(Palette.ink)
            Text("说说你想要什么，Agent 做好后会放在这里").font(.subheadline).foregroundStyle(Palette.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 96)
    }

    @ViewBuilder
    private func menu(_ app: MiniApp) -> some View {
        Button("打开", systemImage: "arrow.up.forward.app") { open(app) }
        Button("让 Agent 修改", systemImage: "wand.and.stars") { ask(MiniAppPresenter.editDraft(app)) }
        Button("添加到主屏幕", systemImage: "plus.square.on.square") { addingToHome = .miniApp(app) }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive) { deleting = app }
    }

    private func open(_ app: MiniApp) {
        Haptics.tap()
        MiniAppPresenter.open(app.id)
    }

    /// A new conversation with `draft` in the composer; the shell closes this sheet to show it.
    private func ask(_ draft: String) {
        LinkInbox.shared.request = LinkRequest(link: .new(draft: draft))
    }
}

/// The bar at the foot of Mini Apps, drawn as a conversation's composer: the request for a new
/// one is typed here, on the page, and sent as a new conversation's first message, which then
/// opens to show it being made. Only text: pictures, voice and the model are the conversation's.
/// The text is the bar's own, so typing redraws the bar and not the grid over it.
private struct MiniAppRequestBar: View {
    /// No app of the user's own yet: ideas over the bar, and the bar asks what they want.
    let first: Bool
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @FocusState private var typing: Bool

    /// What a request begins with, put in as the bar takes the keyboard: what is sent is what shows.
    private static var opening: String { String(localized: "帮我做一个 Mini App：") }

    /// A few things to make, for someone who has not made one yet. Each one plain front-end work
    /// with its data kept on the phone, which a Mini App can do (engine/skills/mini-apps); nothing
    /// that needs the microphone, notifications or sound playing on, which it cannot.
    private static var ideas: [String] {
        [String(localized: "记账本"), String(localized: "背单词卡片"), String(localized: "习惯打卡")]
    }

    private var request: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ready: Bool {
        !request.isEmpty && request != Self.opening.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if first && !ready { ideaChips }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(first ? String(localized: "想要什么 Mini App？") : String(localized: "再做一个 Mini App…"), text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...5)
                    .focused($typing)
                    .inkTint()
                    .padding(.vertical, 11)
                    .padding(.leading, 13)
                    // Down to the bar's own edges, as in the composer.
                    .focusesOnTap($typing, beyond: 5)
                    .accessibilityLabel("做一个 Mini App")
                sendButton
            }
            // The composer's measures: 54 pt with one line.
            .padding(5)
            .composerSurface()
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .readableWidth()
        // The ideas scroll past the bar's padding to the screen's edge, not into the safe area
        // beside it. Cut at the sides only.
        .mask { Rectangle().padding(.vertical, -200) }
        .onChange(of: typing) { _, now in
            if now && text.isEmpty { text = Self.opening } else if !now && text == Self.opening { text = "" }
        }
    }

    /// The conversation's starter prompts, drawn the same way. One puts its request in the bar,
    /// with a numbered list of requirements begun for the user to go on with.
    private var ideaChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.ideas, id: \.self) { idea in
                    Button {
                        Haptics.tap()
                        text = String(localized: "帮我做一个 Mini App：\(idea)。以下是我的要求：\n1. ")
                        typing = true
                    } label: {
                        Text(idea).font(.subheadline).foregroundStyle(Palette.ink.opacity(0.85))
                            .padding(.horizontal, 16)
                            .frame(minHeight: 40)
                            .overlay(Capsule().strokeBorder(Palette.control))
                            .hitTarget()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollClipDisabled()
    }

    /// The composer's: ink once there is something to send. With nothing yet it opens the keyboard.
    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ready ? Palette.onInk : Palette.faint)
                .frame(width: 38, height: 38)
                .background(ready ? Palette.ink : Palette.control, in: Circle())
                .hitTarget()
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("发送消息")
    }

    private func send() {
        guard ready else {
            typing = true
            return
        }
        Haptics.tap()
        let prompt = request
        typing = false
        text = ""
        // The shell starts it and opens it, closing this page's sheet where it is one.
        app.newSessionRequest = NewSessionRequest(prompt: prompt)
    }
}

/// A home screen's grid: as many columns as fit with room between them, and that room the same
/// between the icons as at the page's edges, so the section titles sit on the first icon's edge.
/// A phone upright has four.
private struct IconGrid {
    let icon: CGFloat
    let count: Int
    /// Between two icons, and from the page's edge to the first.
    let gap: CGFloat

    init(width: CGFloat, wide: Bool) {
        icon = wide ? 72 : 60
        let least: CGFloat = wide ? 32 : 28
        count = max(4, Int((width - least) / (icon + least)))
        gap = max(least, ((width - icon * CGFloat(count)) / CGFloat(count + 1)).rounded(.down))
    }

    /// Each column an icon and a gap wide, the icon in its middle; the grid is inset half a gap.
    /// Flexible, not fixed at that width: columns of a fixed width add up to a width of their own,
    /// which held the page as wide as the grid was laid out for (a sheet's first pass at the
    /// window's width on iOS 17), and the page's width is what the grid is laid out from.
    var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .top), count: count)
    }
}

/// An app's icon in the home screen's shape: the picture it drew, else its emoji on its color.
struct MiniAppIcon: View {
    let icon: String
    let color: String
    /// The app's own `icon.png`, edge to edge, in place of the emoji.
    var image: URL?
    let size: CGFloat

    init(icon: String, color: String, image: URL? = nil, size: CGFloat) {
        self.icon = icon
        self.color = color
        self.image = image
        self.size = size
    }

    init(_ app: MiniApp, size: CGFloat) {
        self.init(icon: app.icon, color: app.color, image: app.iconImage, size: size)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let picture = image.flatMap(Self.picture) {
                Image(uiImage: picture).resizable().scaledToFill().frame(width: size, height: size).clipShape(shape)
            } else {
                shape.fill(Color(miniApp: color).gradient)
                    .frame(width: size, height: size)
                    .overlay { Text(verbatim: icon).font(.system(size: size * 0.5)) }
            }
        }
        .accessibilityHidden(true)
    }

    /// Decoded once per file as it is now: the grid draws its icons on every pass.
    private static let pictures = NSCache<NSString, UIImage>()

    private static func picture(_ file: URL) -> UIImage? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        let key = "\(file.path)\u{0}\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = pictures.object(forKey: key) { return hit }
        guard let picture = UIImage(contentsOfFile: file.path) else { return nil }
        pictures.setObject(picture, forKey: key)
        return picture
    }
}

/// A reply's link to a tool on a line of its own (`[记账本](fishapp://ledger)`), as a card that
/// opens it.
struct MiniAppCard: View {
    let id: String
    let title: String
    @State private var app: MiniApp?
    @State private var looked = false

    /// The id, when `paragraph` is nothing but a link to an app.
    static func linkedApp(_ paragraph: String) -> (id: String, title: String)? {
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.wholeMatch(of: /\[([^\]\n]+)\]\(fishapp:\/\/([a-z0-9-]+)\/?\)/) else { return nil }
        return (String(match.output.2), String(match.output.1))
    }

    var body: some View {
        Button {
            Haptics.tap()
            MiniAppPresenter.open(id)
        } label: {
            HStack(spacing: 12) {
                MiniAppIcon(icon: app?.icon ?? MiniApp.defaultIcon, color: app?.color ?? MiniApp.defaultColor, image: app?.iconImage, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app?.name ?? title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(looked && app == nil ? String(localized: "Mini App 已删除") : app?.summary ?? String(localized: "Mini App"))
                        .font(.footnote).foregroundStyle(Palette.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if app != nil {
                    Text("打开")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.onInk)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Palette.ink, in: Capsule())
                }
            }
            .padding(12)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(looked && app == nil)
        .task(id: id) {
            app = MiniAppStore.shared.app(id)
            looked = true
        }
    }
}
