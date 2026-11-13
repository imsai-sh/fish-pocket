import SwiftUI
import WatchConnectivity

/// 「Apple Watch」 under 分享 in 设置: whether the watch app is on the wrist yet, and how to put it
/// there. The way differs by where this copy came from: an App Store install adds it from the
/// iPhone's Watch app, a TestFlight one from TestFlight's own page for the build.
struct WatchSetupPage: View {
    enum Channel: CaseIterable, Identifiable {
        case appStore, testFlight
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .appStore: "App Store 版"
            case .testFlight: "TestFlight 版"
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var channel: Channel = AppDistribution.channel == .testFlight ? .testFlight : .appStore
    @State private var pairing = WatchPairing.current

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                StatusCard(pairing: pairing)
                VStack(spacing: 12) {
                    tabs
                    if let note = channelNote {
                        Text(note).font(.footnote).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 4)
                steps
                tip
                afterwards
                Text("手表上不跑引擎，内容都由 iPhone 发过去：iPhone 在身边、Fish Pocket 在运行时才会更新。需要 watchOS 10 或更高版本。")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.grouped)
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        // Installing happens in another app: look again every couple of seconds while this page is open.
        .task {
            while !Task.isCancelled {
                pairing = WatchPairing.current
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 18) {
            WatchIllustration()
                .frame(height: 230)
                .padding(.top, 8)
            VStack(spacing: 6) {
                Text("把 Fish Pocket 戴在手腕上")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Palette.ink)
                Text("抬腕看会话进度，等你确认时轻轻一震，允许或拒绝不用掏手机。")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Palette.background)
                .overlay(alignment: .top) {
                    // A faint wash of the waiting colour behind the watch.
                    RadialGradient(colors: [Palette.waiting.opacity(0.16), .clear], center: .center, startRadius: 10, endRadius: 170)
                        .frame(height: 300)
                        .offset(y: -20)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Palette.stroke) }
    }

    // MARK: Channel

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Channel.allCases) { item in
                Button {
                    if channel != item { Haptics.select() }
                    withAnimation(.snappy(duration: 0.25)) { channel = item }
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(channel == item ? .semibold : .medium))
                        .foregroundStyle(channel == item ? Palette.onInk : Palette.secondary)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 36)
                        .background { if channel == item { Capsule().fill(Palette.ink) } }
                        .hitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(channel == item ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .background(Palette.control, in: Capsule())
    }

    /// Which tab fits this copy, said once the store has told us.
    private var channelNote: LocalizedStringKey? {
        switch (AppDistribution.channel, channel) {
        case (.appStore, .appStore): "你的 Fish Pocket 来自 App Store，按这一页操作。"
        case (.appStore, .testFlight): "你的 Fish Pocket 来自 App Store，这一页是给 TestFlight 用户的。"
        case (.testFlight, .testFlight): "你的 Fish Pocket 来自 TestFlight，按这一页操作。"
        case (.testFlight, .appStore): "你的 Fish Pocket 来自 TestFlight，这一页是给 App Store 用户的。"
        default: nil
        }
    }

    // MARK: Steps

    private struct Step {
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private var stepList: [Step] {
        switch channel {
        case .appStore:
            [
                Step(title: "打开 iPhone 上的「Watch」App", detail: "就是用来配对手表的那个 App。"),
                Step(title: "在「我的手表」里往下滑", detail: "找到「可用 App」一栏里的 Fish Pocket。"),
                Step(title: "轻点「安装」", detail: "装好后手表上会出现 Fish Pocket 的图标，打开一次就连上了。"),
            ]
        case .testFlight:
            [
                Step(title: "打开 iPhone 上的 TestFlight", detail: "要和装 Fish Pocket 的是同一台 iPhone。"),
                Step(title: "轻点 Fish Pocket", detail: "进入这个 App 的详情页。"),
                Step(title: "打开「在 Apple Watch 上显示 App」", detail: "在详情页下方，和「自动更新」在同一组。打开后手表就开始安装，装好后在手表上打开一次就连上了。"),
            ]
        }
    }

    private var steps: some View {
        let list = stepList
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Text(verbatim: "\(index + 1)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(Palette.onInk)
                            .frame(width: 30, height: 30)
                            .background(Palette.ink, in: Circle())
                        if index < list.count - 1 {
                            Rectangle()
                                .fill(Palette.stroke)
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                                .padding(.vertical, 4)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 5)
                        Text(step.detail)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if index == 0 { openButton.padding(.top, 8) }
                    }
                    .padding(.bottom, index < list.count - 1 ? 18 : 0)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.stroke) }
        .id(channel)
        .transition(.opacity)
    }

    /// Straight into the app the steps happen in.
    private var openButton: some View {
        let (title, url): (LocalizedStringKey, URL) = switch channel {
        case .appStore: ("打开 Watch App", URL(string: "itms-watchs://")!)
        case .testFlight: ("打开 TestFlight", URL(string: "itms-beta://")!)
        }
        return Button {
            Haptics.tap()
            openURL(url) { opened in
                if !opened { app.showToast(String(localized: "没能打开，请在主屏幕上找到它")) }
            }
        } label: {
            Label(title, systemImage: "arrow.up.right")
                .labelStyle(TrailingIconLabel())
        }
        .buttonStyle(.capsule(height: 38, fill: false))
    }

    private var tip: some View {
        let (title, text): (LocalizedStringKey, LocalizedStringKey) = switch channel {
        case .appStore:
            ("也可以直接在手表上装", "在手表上打开 App Store 搜索 Fish Pocket。想让以后的 App 自动装到手表上，在 Watch App 的「通用」里打开「自动安装 App」。")
        case .testFlight:
            ("没看到这个开关？", "先确认 TestFlight 里的 Fish Pocket 已经装好，详情页里「Apple Watch」一项写着「是」，手表系统是 watchOS 10 或更高版本。仍然没有的话，打开 iPhone 上的 Watch App，在「可用 App」里也能装。")
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Palette.waiting)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(text).font(.subheadline).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Palette.waiting.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .id(channel)
        .transition(.opacity)
    }

    // MARK: Afterwards

    private var afterwards: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("装好之后")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondary)
                .textCase(.uppercase)
            feature("list.bullet.rectangle", "抬腕看会话", "正在跑的、等你答复的、刚做完的，一眼就清楚。")
            feature("bell.badge", "有事找你时震动", "Agent 等你确认或做完一轮，手腕上轻轻提醒。")
            feature("checkmark.circle", "手腕上允许或拒绝", "需要授权的操作直接在手表上放行，不用掏手机。")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.stroke) }
    }

    private func feature(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 36, height: 36)
                .background(Palette.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(detail).font(.footnote).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// What WatchConnectivity says about the wrist. Read on demand: the answers are only
/// meaningful once `WatchLink` has activated the session at launch.
enum WatchPairing: Equatable {
    case checking
    case unpaired
    case notInstalled
    case installed

    @MainActor
    static var current: WatchPairing {
        guard WCSession.isSupported() else { return .unpaired }
        let session = WCSession.default
        guard session.activationState == .activated else { return .checking }
        if !session.isPaired { return .unpaired }
        return session.isWatchAppInstalled ? .installed : .notInstalled
    }
}

/// Where things stand, at the top of the guide.
private struct StatusCard: View {
    let pairing: WatchPairing

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
                    .background(Palette.control, in: Circle())
                if pairing != .checking {
                    Circle()
                        .fill(dot)
                        .frame(width: 12, height: 12)
                        .overlay { Circle().strokeBorder(Palette.background, lineWidth: 2.5) }
                        .offset(x: 1, y: 1)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(detail).font(.footnote).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if pairing == .checking { ProgressView() }
        }
        .padding(16)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.stroke) }
        .accessibilityElement(children: .combine)
        .animation(.snappy, value: pairing)
    }

    private var icon: String {
        switch pairing {
        case .unpaired: "applewatch.slash"
        case .installed: "applewatch.radiowaves.left.and.right"
        case .checking, .notInstalled: "applewatch"
        }
    }

    private var dot: Color {
        switch pairing {
        case .installed: Palette.running
        case .notInstalled: Palette.waiting
        case .checking, .unpaired: Palette.faint
        }
    }

    private var title: LocalizedStringKey {
        switch pairing {
        case .checking: "正在查看手表…"
        case .unpaired: "没有配对的 Apple Watch"
        case .notInstalled: "手表上还没装 Fish Pocket"
        case .installed: "已经装在 Apple Watch 上"
        }
    }

    private var detail: LocalizedStringKey {
        switch pairing {
        case .checking: "稍等一下。"
        case .unpaired: "先在 iPhone 的 Watch App 里配对手表，再按下面的步骤安装。"
        case .notInstalled: "按下面的步骤装上，装好后这里会自动更新。"
        case .installed: "在手表上打开 Fish Pocket 就能看到会话。"
        }
    }
}

/// Title first, the icon after it: the arrow says the button leaves the app.
private struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.font(.caption.weight(.bold))
        }
    }
}

/// An Apple Watch drawn in shapes, showing what the wrist sees while a session waits:
/// the fish with its badge, the session, and the two answers.
private struct WatchIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private let caseWidth: CGFloat = 150
    private let caseHeight: CGFloat = 178

    var body: some View {
        ZStack {
            // The band, behind the case.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.20), Color(white: 0.30)], startPoint: .top, endPoint: .bottom))
                .frame(width: caseWidth - 34, height: 236)
                .overlay {
                    VStack(spacing: 7) {
                        ForEach(0..<3, id: \.self) { _ in Capsule().fill(.black.opacity(0.25)).frame(width: 4, height: 4) }
                    }
                    .offset(y: 100)
                }
            // Crown and side button.
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.30)], startPoint: .top, endPoint: .bottom))
                .frame(width: 9, height: 30)
                .offset(x: caseWidth / 2 + 1, y: -28)
            Capsule()
                .fill(Color(white: 0.32))
                .frame(width: 5, height: 34)
                .offset(x: caseWidth / 2, y: 18)
            // The case.
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: caseWidth, height: caseHeight)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .fill(.black)
                .frame(width: caseWidth - 12, height: caseHeight - 12)
            screen
                .frame(width: caseWidth - 26, height: caseHeight - 26)
        }
        .frame(width: caseWidth + 20)
        .accessibilityHidden(true)
        .onAppear { if !reduceMotion { breathing = true } }
    }

    private var screen: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .strokeBorder(Palette.waiting, lineWidth: 2.5)
                    .frame(width: 58, height: 58)
                    .scaleEffect(breathing ? 1.08 : 1)
                    .opacity(breathing ? 0.55 : 1)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathing)
                Image("ShareMascot")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .background(LinearGradient(colors: [Color(red: 0.86, green: 0.93, blue: 1), .white], startPoint: .top, endPoint: .bottom))
                    .clipShape(Circle())
                    .frame(width: 58, height: 58)
                Text(verbatim: "!")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.black)
                    .frame(width: 18, height: 18)
                    .background(Palette.waiting, in: Circle())
                    .offset(x: 4, y: -2)
            }
            Text("等你允许")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(Color(white: 0.2), in: Capsule())
                    .foregroundStyle(.white)
                Image(systemName: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(Palette.running, in: Capsule())
                    .foregroundStyle(.black)
            }
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 10)
        }
    }
}

/// The way into 「Apple Watch」 in 设置, under the share row: a watch on a dark tile, and how it stands.
struct WatchSetupRow: View {
    @State private var pairing = WatchPairing.current

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "applewatch")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.08)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Watch")
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .onAppear { pairing = WatchPairing.current }
    }

    private var subtitle: LocalizedStringKey {
        pairing == .installed ? "已安装在手表上" : "在手腕上看会话、做确认"
    }
}
