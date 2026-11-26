import SwiftUI
import UIKit

// MARK: - Windows

/// The call screen's own window, above the app and anything it presents, so a call started from
/// any page covers it all; minimized, the window goes and `CallBubbleWindow` floats in its place.
/// Both look like the app: its light or dark appearance, whichever the app is in.
@MainActor
final class CallWindow {
    private var window: UIWindow?
    private var host: UIHostingController<AnyView>?
    /// The window that had the keyboard focus before: it gets it back.
    private weak var previousKey: UIWindow?

    func show(_ call: VoiceCall) {
        guard let scene = Self.activeScene else { return }
        if window == nil || window?.windowScene !== scene {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .normal + 1
            window.backgroundColor = .clear
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            self.window = window
            self.host = host
        }
        guard let window, let host else { return }
        window.overrideUserInterfaceStyle = Self.appStyle(in: scene, besides: window)
        host.rootView = AnyView(CallScreen(call: call).environment(call.app))
        host.view.accessibilityViewIsModal = true
        let bounds = scene.coordinateSpace.bounds
        guard window.isHidden else {
            window.frame = bounds
            return
        }
        // The window itself slides up from below the screen: its view keeps its layout.
        previousKey = scene.windows.first { $0.isKeyWindow && $0 !== window }
        window.frame = bounds.offsetBy(dx: 0, dy: bounds.height)
        window.makeKeyAndVisible()
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            window.frame = bounds
        }
    }

    func hide(release: Bool = false) {
        guard let window, let host, !window.isHidden else {
            if release { self.window = nil; self.host = nil }
            return
        }
        let bounds = window.windowScene?.coordinateSpace.bounds ?? window.bounds
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseIn]) {
            window.frame = bounds.offsetBy(dx: 0, dy: bounds.height)
        } completion: { _ in
            window.isHidden = true
            window.frame = bounds
            self.previousKey?.makeKey()
            if release {
                host.rootView = AnyView(EmptyView())
                self.window = nil
                self.host = nil
            }
        }
    }

    static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// The appearance the app's own window is in (the user can fix it to light or dark in the app).
    static func appStyle(in scene: UIWindowScene, besides window: UIWindow?) -> UIUserInterfaceStyle {
        scene.windows.first { $0 !== window && $0.windowLevel == .normal }?.overrideUserInterfaceStyle ?? .unspecified
    }
}

/// A minimized call: a small round window over the app, like picture in picture. It never moves
/// the app's own layout; it can be dragged and settles against the nearer side; a tap brings the
/// call back.
@MainActor
final class CallBubbleWindow: NSObject {
    static let size = CGSize(width: 84, height: 100)

    private var window: UIWindow?
    private var host: UIHostingController<AnyView>?
    /// Where it was left, as the centre's share of the scene, for the next time.
    private var anchor = CGPoint(x: 1, y: 0.28)

    func show(_ call: VoiceCall) {
        guard let scene = CallWindow.activeScene else { return }
        if window == nil || window?.windowScene !== scene {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .normal + 1
            window.backgroundColor = .clear
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.view.backgroundColor = .clear
            host.view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
            window.rootViewController = host
            self.window = window
            self.host = host
        }
        guard let window, let host else { return }
        window.overrideUserInterfaceStyle = CallWindow.appStyle(in: scene, besides: window)
        host.rootView = AnyView(CallBubble(call: call).environment(call.app))
        window.frame = frame(in: scene)
        guard window.isHidden else { return }
        window.alpha = 0
        window.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        window.isHidden = false
        UIView.animate(withDuration: 0.42, delay: 0.12, usingSpringWithDamping: 0.72, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            window.alpha = 1
            window.transform = .identity
        }
    }

    func hide(release: Bool = false) {
        guard let window, !window.isHidden else {
            if release { self.window = nil; host = nil }
            return
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn]) {
            window.alpha = 0
            window.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        } completion: { _ in
            window.isHidden = true
            window.transform = .identity
            window.alpha = 1
            if release {
                self.host?.rootView = AnyView(EmptyView())
                self.window = nil
                self.host = nil
            }
        }
    }

    /// The bubble's frame for `anchor`: against a side, inside the safe area.
    private func frame(in scene: UIWindowScene) -> CGRect {
        let bounds = scene.coordinateSpace.bounds
        let insets = scene.windows.first { $0 !== window }?.safeAreaInsets ?? .zero
        let margin: CGFloat = 8
        let size = Self.size
        let minX = insets.left + margin, maxX = bounds.width - insets.right - margin - size.width
        let minY = insets.top + margin, maxY = bounds.height - insets.bottom - margin - size.height - 60
        let x = anchor.x < 0.5 ? minX : maxX
        let y = min(max(anchor.y * bounds.height - size.height / 2, minY), max(minY, maxY))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let window, let scene = window.windowScene else { return }
        let bounds = scene.coordinateSpace.bounds
        switch pan.state {
        case .changed:
            let move = pan.translation(in: nil)
            window.center = CGPoint(x: window.center.x + move.x, y: window.center.y + move.y)
            pan.setTranslation(.zero, in: nil)
        case .ended, .cancelled:
            // A flick carries it on a little before it settles.
            let velocity = pan.velocity(in: nil)
            let x = window.center.x + velocity.x * 0.15
            let y = window.center.y + velocity.y * 0.15
            anchor = CGPoint(x: x / bounds.width, y: y / bounds.height)
            let target = frame(in: scene)
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                window.frame = target
            }
        default:
            break
        }
    }
}

// MARK: - Screen

/// The call, the app's way: its own background and ink, one vermilion (`Palette.spot`) for her
/// voice. In the middle, large, the face of the one on the line: it moves with both voices and
/// while she thinks; under it the name and how the call stands; at the bottom three round
/// buttons, with a card above them when something needs the user.
struct CallScreen: View {
    @Environment(AppModel.self) private var app
    let call: VoiceCall
    @State private var settingsOpen = false

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let failure = call.failure {
                    Spacer(minLength: 0)
                    CallFailure(message: failure, settings: { settingsOpen = true }, close: call.dismiss)
                    Spacer(minLength: 0)
                } else {
                    // The face is the call: it carries both voices and the thinking. A little
                    // above the middle, where the eye rests.
                    Spacer(minLength: 16)
                    VStack(spacing: 18) {
                        CallAvatar(call: call, size: 188)
                        VStack(spacing: 6) {
                            Text(call.title)
                                .font(.title.weight(.semibold))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            CallStatusLine(call: call)
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 48)
                    Spacer(minLength: 16)
                    footer
                        .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 12)
            if call.ended && call.failure == nil {
                CallEnded(call: call)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: call.ended)
        .sheet(isPresented: $settingsOpen) {
            NavigationStack {
                VoiceCallSettingsPage()
                    .closeButton { settingsOpen = false }
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                Haptics.select()
                CallCenter.shared.minimize()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
                    .callGlass(in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(CallPressStyle())
            .accessibilityLabel("最小化通话")
            .opacity(call.ended ? 0 : 1)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 22) {
            if let deadline = call.idleDeadline {
                CallIdleCard(deadline: deadline, keepTalking: call.keepTalking)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if call.waitingOnUser {
                CallWaitingCard()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let notice = call.notice {
                CallNoticeCapsule(notice: notice)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            HStack(spacing: 34) {
                CallControl(
                    symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                    label: call.muted ? "取消静音" : "静音",
                    on: call.muted,
                    action: call.toggleMute
                )
                CallControl(symbol: "phone.down.fill", label: "挂断", hangUp: true, action: call.hangUp)
                CallControl(
                    symbol: call.externalRoute ? "headphones" : "speaker.wave.2.fill",
                    label: call.externalRoute ? "耳机" : "扬声器",
                    on: call.speaker && !call.externalRoute,
                    action: call.toggleSpeaker
                )
                .disabled(call.externalRoute)
            }
            .disabled(call.ended)
        }
        .frame(maxWidth: 520)
        .animation(.smooth(duration: 0.35), value: call.idleDeadline)
        .animation(.smooth(duration: 0.35), value: call.waitingOnUser)
        .animation(.smooth(duration: 0.35), value: call.notice)
    }
}

/// 在听 · 01:23
private struct CallStatusLine: View {
    let call: VoiceCall

    var body: some View {
        HStack(spacing: 6) {
            Text(phaseText)
                .contentTransition(.opacity)
            if let start = call.startedAt {
                Text(verbatim: "·")
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(verbatim: CallDuration.text(from: start, to: call.endedAt ?? context.date))
                        .monospacedDigit()
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(Palette.secondary)
        .animation(.smooth(duration: 0.25), value: phaseText)
    }

    private var phaseText: String {
        if call.ended { return String(localized: "通话结束") }
        if call.waitingOnUser { return String(localized: "等你确认") }
        switch call.phase {
        case .connecting: return String(localized: "正在接通…")
        case .listening: return call.muted ? String(localized: "已静音") : String(localized: "在听")
        case .thinking: return String(localized: "在想")
        case .speaking: return String(localized: "在说")
        }
    }
}

enum CallDuration {
    static func text(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3_600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%02d:%02d", minutes, rest)
    }
}

// MARK: - Face

/// The one on the line: a Bot's own face, or the app's for a conversation, inside a ring of short
/// ticks (`CallDial`) that carries the call: they rise with her voice in vermilion and with the
/// user's in ink, a light sweeps round them while the answer is being worked out, and they fill
/// one by one while the call connects. A drawn character also breathes and lifts with her voice; a
/// picture (the user's photo, or the app's 大肥鱼) holds still, as bouncing a photo looks wrong.
struct CallAvatar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let call: VoiceCall
    let size: CGFloat
    @State private var dial = CallDial()

    var body: some View {
        let speaking = call.phase == .speaking
        let level = CGFloat(speaking ? call.levels.output : (call.muted ? 0 : call.levels.input))
        let moves = !reduceMotion && !picture
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let breath = moves ? CGFloat(sin(time * 1.6)) * 0.012 : 0
            ZStack {
                // A little wider than the face's frame: the ticks' loudest reach spills past it.
                Canvas { graphics, canvas in
                    dial.draw(in: &graphics, size: canvas, radius: size / 2, time: time,
                              phase: call.phase, level: level, still: reduceMotion)
                }
                .frame(width: size + 120, height: size + 120)
                face
                    .scaleEffect(1 + breath + (speaking && moves ? level * 0.07 : 0))
                    .rotationEffect(.degrees(speaking && moves ? Double(sin(time * 5)) * Double(level) * 3 : 0))
            }
        }
        // Room for the ticks, so loud ones stay clear of the name below.
        .frame(width: size + 90, height: size + 90)
        .animation(.smooth(duration: 0.14), value: level)
        .animation(.smooth(duration: 0.4), value: call.phase)
        .accessibilityHidden(true)
    }

    /// A photo or the app's 大肥鱼, not a drawn character.
    private var picture: Bool {
        guard let bot = call.bot else { return true }
        return call.app.botTeam.showsPicture(bot)
    }

    @ViewBuilder
    private var face: some View {
        if let bot = call.bot {
            // A picture would hop while she thinks (`BotPictureMotion`): in the call it stays still.
            BotAvatar(bot: bot, size: size, live: true, mood: picture ? .idle : mood)
        } else {
            Image("LaunchMark")
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
    }

    private var mood: BotMood {
        if call.waitingOnUser { return .alert }
        return call.phase == .thinking ? .thinking : .idle
    }
}

/// The ring of ticks round the call's face. Quiet, it is a faint ring of dots; with a voice the
/// ticks stretch out by different lengths, mirrored left and right (hers vermilion and longer, the
/// user's ink); while she thinks they hold still and a light runs round them with a tail; while
/// the call connects they light up one by one from the top. Each tick eases to where it should
/// be, so the levels' twenty readings a second come out smooth. It keeps that state between
/// frames, so one dial belongs to one face.
final class CallDial {
    private static let count = 96
    private var length = [CGFloat](repeating: 3, count: count)
    private var alpha = [CGFloat](repeating: 0.18, count: count)
    /// 0 ink … 1 vermilion.
    private var warmth = [CGFloat](repeating: 0, count: count)
    private var last: TimeInterval?

    func draw(in context: inout GraphicsContext, size: CGSize, radius: CGFloat, time: TimeInterval,
              phase: VoiceCall.Phase, level: CGFloat, still: Bool) {
        let dt = min(0.05, max(0, time - (last ?? time)))
        last = time
        // With reduced motion the clock stands still: the ticks go straight to where they belong.
        let ease = still ? 1 : 1 - CGFloat(exp(-dt * 14))
        let scale = radius / 94
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let inner = radius + 12 * scale
        let n = Self.count
        let turn = 2 * Double.pi
        let head = (time * 1.5).truncatingRemainder(dividingBy: turn)
        let filled = (time * 0.9).truncatingRemainder(dividingBy: 1.25)
        let breath = still ? 0 : 0.06 * CGFloat(sin(time * 1.6))
        let style = StrokeStyle(lineWidth: 2.2 * scale, lineCap: .round)

        for i in 0..<n {
            let around = Double(i) / Double(n) * turn
            var reach: CGFloat = 3, light: CGFloat = 0.18, warm: CGFloat = 0
            switch phase {
            case .speaking, .listening:
                let speaking = phase == .speaking
                // 0 at the top, 1 at the bottom, the same on both sides.
                let u = Double(min(i, n - i)) / Double(n / 2)
                let t = still ? 0 : time
                let wave = 0.55 + 0.45 * sin(u * 9 + t * 7.1) * sin(u * 4.3 - t * 3.7 + 1.3) + 0.25 * sin(u * 17 + t * 11)
                reach = 3 + (speaking ? 30 : 18) * level * max(0.08, CGFloat(wave))
                light = speaking ? 0.3 + level * 0.7 : 0.18 + breath + level * 0.82
                warm = speaking ? 1 : 0
            case .thinking:
                var behind = (around - head).truncatingRemainder(dividingBy: turn)
                if behind < 0 { behind += turn }
                let tail = CGFloat(exp(-(turn - behind).truncatingRemainder(dividingBy: turn) * 1.6))
                reach = 3 + tail * 7
                light = 0.15 + tail * 0.85
                warm = light > 0.6 ? 1 : 0
            case .connecting:
                let lit: CGFloat = Double(i) / Double(n) < filled ? 1 : 0
                // A full ring fades before it starts again.
                let fade = filled > 1 ? CGFloat(1.25 - filled) * 4 : 1
                reach = 3 + lit * 3
                light = 0.15 + lit * 0.55 * fade
            }
            length[i] += (reach - length[i]) * ease
            alpha[i] += (light - alpha[i]) * ease
            warmth[i] += (warm - warmth[i]) * ease

            let angle = around - .pi / 2
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let outer = inner + length[i] * scale
            var tick = Path()
            tick.move(to: CGPoint(x: centre.x + direction.x * inner, y: centre.y + direction.y * inner))
            tick.addLine(to: CGPoint(x: centre.x + direction.x * outer, y: centre.y + direction.y * outer))
            if warmth[i] < 0.99 {
                context.opacity = alpha[i] * (1 - warmth[i]) * (phase == .thinking ? 1 : 0.85)
                context.stroke(tick, with: .color(Palette.ink), style: style)
            }
            if warmth[i] > 0.01 {
                context.opacity = alpha[i] * warmth[i]
                context.stroke(tick, with: .color(Palette.spot), style: style)
            }
        }
        context.opacity = 1
    }
}

// MARK: - Cards

/// Nobody has talked for a while: the call ends at `deadline` unless the user speaks or goes on.
private struct CallIdleCard: View {
    let deadline: Date
    let keepTalking: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Palette.spot)
                .frame(width: 8, height: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("没听到声音，\(seconds) 秒后挂断")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                    Text("说句话也能接着聊")
                        .font(.caption)
                        .foregroundStyle(Palette.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(action: keepTalking) {
                Text("继续通话")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.onInk)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// The conversation waits on the user: the call steps aside to let them answer there.
private struct CallWaitingCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Palette.waiting)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要你确认一下").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Text("在对话里处理完，通话会接着进行").font(.caption).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 8)
            Button {
                Haptics.select()
                CallCenter.shared.minimize()
            } label: {
                Text("去处理")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.onInk)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct CallNoticeCapsule: View {
    let notice: VoiceCall.Notice

    var body: some View {
        HStack(spacing: 8) {
            switch notice {
            case .reconnecting:
                ProgressView().controlSize(.small)
                Text("网络不稳定，正在重连…")
            case .paused:
                Image(systemName: "pause.fill").imageScale(.small)
                Text("通话被系统暂停，结束后自动继续")
            case .problem(let message):
                Circle().fill(Palette.waiting).frame(width: 7, height: 7)
                Text(message).lineLimit(2)
            }
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.field, in: Capsule())
    }
}

/// The call could not start, or had to stop: why, and the way to fix it.
private struct CallFailure: View {
    let message: String
    let settings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("通话没能继续")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button(action: settings) {
                    Text("语音通话设置")
                }
                .buttonStyle(.capsule(height: 50))
                Button(action: close) {
                    Text("关闭")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Palette.control, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 32)
    }
}

/// 通话结束, how long it was, and why if it ended by itself, for a moment before the screen goes.
private struct CallEnded: View {
    let call: VoiceCall

    var body: some View {
        ZStack {
            // Nearly opaque: the face sits right behind the words.
            Palette.background.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 6) {
                Text("通话结束").font(.title2.weight(.semibold)).foregroundStyle(Palette.ink)
                if let start = call.startedAt {
                    Text(verbatim: CallDuration.text(from: start, to: call.endedAt ?? Date()))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Palette.secondary)
                }
                if let reason = call.endReason {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                        .padding(.horizontal, 32)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Controls

/// A round button: glass, ink when on; the hang-up button vermilion.
private struct CallControl: View {
    @Environment(\.isEnabled) private var enabled
    let symbol: String
    let label: LocalizedStringKey
    var on = false
    var hangUp = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: hangUp ? 25 : 22, weight: .semibold))
                .foregroundStyle(hangUp ? .white : (on ? Palette.onInk : Palette.ink))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: hangUp ? 72 : 64, height: hangUp ? 72 : 64)
                .background {
                    if hangUp {
                        Circle().fill(Palette.spot)
                    } else if on {
                        Circle().fill(Palette.ink)
                    }
                }
                .callGlass(in: Circle(), when: !hangUp && !on)
                .contentShape(Circle())
        }
        .buttonStyle(CallPressStyle())
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Pressed buttons give a little.
private struct CallPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

extension View {
    /// Liquid glass from iOS 26; before that the app's control grey.
    @ViewBuilder
    func callGlass<S: Shape>(in shape: S, when enabled: Bool = true) -> some View {
        if !enabled {
            self
        } else if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(Palette.control, in: shape)
        }
    }
}

// MARK: - Bubble

/// A minimized call: the face of the one on the line with the call's ring around it (vermilion
/// while she speaks, ink while the user does) and the call's length. A tap brings the call back.
struct CallBubble: View {
    let call: VoiceCall

    var body: some View {
        let speaking = call.phase == .speaking
        let level = CGFloat(speaking ? call.levels.output : (call.muted ? 0 : call.levels.input))
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(Palette.background)
                face
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                Circle()
                    .strokeBorder(speaking ? Palette.spot : Palette.ink.opacity(0.25 + level * 0.6), lineWidth: 2.5 + level * 2.5)
            }
            .frame(width: 68, height: 68)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .overlay(alignment: .topTrailing) {
                if call.waitingOnUser {
                    Circle()
                        .fill(Palette.waiting)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Palette.background, lineWidth: 2))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            if let start = call.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(verbatim: CallDuration.text(from: start, to: context.date))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Palette.onInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Palette.ink))
                }
            }
        }
        .frame(width: CallBubbleWindow.size.width, height: CallBubbleWindow.size.height)
        .animation(.smooth(duration: 0.15), value: level)
        .animation(.smooth(duration: 0.3), value: call.waitingOnUser)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.select()
            CallCenter.shared.expand()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(call.title))
        .accessibilityHint("返回通话")
    }

    @ViewBuilder
    private var face: some View {
        if let bot = call.bot {
            BotAvatar(bot: bot, size: 60, live: false)
        } else {
            Image("LaunchMark").resizable().scaledToFill()
        }
    }
}
