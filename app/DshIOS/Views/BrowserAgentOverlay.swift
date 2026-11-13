import SwiftUI

/// The agent at work in the workbench browser: a glow round the page, a pointer where it clicks,
/// types, picks or scrolls, and what it is doing in a capsule. It is drawn over the web view and
/// takes no touches, so the user can reach the page through it at any time; a touch takes over,
/// and all of it goes (`BrowserPresence`).
struct BrowserAgentOverlay: View {
    let model: BrowserModel
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presence: BrowserPresence { model.presence }

    /// The agent's turn is still going. A session the list does not hold yet counts as going;
    /// the presence's own timeout ends that.
    private var running: Bool {
        guard let driver = presence.driver else { return false }
        return app.sessions[driver]?.running ?? true
    }

    private var shown: Bool { presence.driver != nil && (presence.action != nil || running) }

    var body: some View {
        GeometryReader { geometry in
            let area = visibleArea(in: geometry.size)
            ZStack {
                if shown {
                    AgentEdgeGlow(still: reduceMotion)
                        .transition(.opacity)
                    if let pointer = presence.pointer {
                        AgentPointer(pointer: pointer, scrolling: presence.action == .scroll, still: reduceMotion)
                            .position(x: area.minX + pointer.at.x * area.width, y: area.minY + pointer.at.y * area.height)
                            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.12), value: pointer.at)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                    }
                    AgentStatus(action: presence.action, still: reduceMotion)
                        .padding(12)
                        // Out of the way of the pointer: at the foot when it works near the top.
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: (presence.pointer?.at.y ?? 1) < 0.2 ? .bottom : .top)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: shown)
        .animation(.smooth(duration: 0.3), value: presence.pointer == nil)
        .animation(.smooth(duration: 0.3), value: (presence.pointer?.at.y ?? 1) < 0.2)
        .onChange(of: running) { _, now in
            // The turn is over: nothing is left at the page.
            if !now, presence.action == nil { presence.dismiss() }
        }
    }

    /// Where the page's visible part sits in the web view: inside whatever the web view keeps clear.
    private func visibleArea(in size: CGSize) -> CGRect {
        let inset = model.webView.scrollView.adjustedContentInset
        return CGRect(
            x: inset.left, y: inset.top,
            width: max(0, size.width - inset.left - inset.right),
            height: max(0, size.height - inset.top - inset.bottom))
    }
}

/// A soft glow at the page's edges, in the colour the app uses for an agent at work. It breathes
/// slowly; with Reduce Motion it holds still.
private struct AgentEdgeGlow: View {
    let still: Bool

    var body: some View {
        if still {
            glow(1)
        } else {
            glow(1).phaseAnimator([0.55, 1]) { content, phase in
                content.opacity(phase)
            } animation: { _ in .easeInOut(duration: 1.4) }
        }
    }

    private func glow(_ strength: Double) -> some View {
        ZStack {
            Rectangle().strokeBorder(Palette.running.opacity(0.9 * strength), lineWidth: 2)
            Rectangle().strokeBorder(Palette.running.opacity(0.45 * strength), lineWidth: 14).blur(radius: 12)
        }
        .accessibilityHidden(true)
    }
}

/// The agent's finger: a dot like the iPad's pointer, in the agent's colour so it shows on any page.
/// It presses in and sends out a ring where it clicks, and draws a short stroke where it scrolls.
private struct AgentPointer: View {
    let pointer: BrowserPresence.Pointer
    let scrolling: Bool
    let still: Bool

    private static let size: CGFloat = 26

    var body: some View {
        Circle()
            .fill(Palette.running)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .overlay {
                if scrolling {
                    Image(systemName: pointer.down ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.opacity)
                }
            }
            .frame(width: Self.size, height: Self.size)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .background { ring }
            .keyframeAnimator(initialValue: 1.0, trigger: pointer.presses) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                // With Reduce Motion the ring alone marks a press.
                CubicKeyframe(still ? 1 : 0.72, duration: 0.1)
                SpringKeyframe(1, duration: 0.35, spring: .bouncy)
            }
            .keyframeAnimator(initialValue: Stroke(), trigger: pointer.swipes) { content, stroke in
                content.scaleEffect(stroke.scale).offset(y: stroke.offset)
            } keyframes: { _ in
                // A finger scrolls a page down by moving up. With Reduce Motion the arrow alone says which way.
                let travel: CGFloat = still ? 0 : pointer.down ? 34 : -34
                let pressed: CGFloat = still ? 1 : 0.82
                KeyframeTrack(\.offset) {
                    MoveKeyframe(travel)
                    CubicKeyframe(-travel, duration: 0.32)
                    SpringKeyframe(0, duration: 0.3, spring: .smooth)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(pressed, duration: 0.06)
                    LinearKeyframe(pressed, duration: 0.26)
                    SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                }
            }
            .animation(.smooth(duration: 0.2), value: scrolling)
            .accessibilityHidden(true)
    }

    /// The ring a press sends out. With Reduce Motion it lights up and fades where it is.
    private var ring: some View {
        Circle()
            .strokeBorder(Palette.running, lineWidth: 2)
            .frame(width: Self.size, height: Self.size)
            .keyframeAnimator(initialValue: Ring(), trigger: pointer.presses) { content, ring in
                content.scaleEffect(ring.scale).opacity(ring.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(0.9)
                    LinearKeyframe(0, duration: still ? 0.6 : 0.5)
                }
                KeyframeTrack(\.scale) {
                    MoveKeyframe(still ? 1.6 : 1)
                    CubicKeyframe(still ? 1.6 : 2.8, duration: 0.5)
                }
            }
    }

    private struct Ring {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    private struct Stroke {
        var offset: CGFloat = 0
        var scale: CGFloat = 1
    }
}

/// What the agent is doing, in a capsule of the system's glass at the page's top.
private struct AgentStatus: View {
    let action: BrowserPresence.Action?
    let still: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.running)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18)
            Text(title)
                .foregroundStyle(Palette.ink)
                .contentTransition(.opacity)
        }
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .agentStatusSurface()
        .animation(still ? nil : .smooth(duration: 0.25), value: action)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch action {
        case .open: "globe"
        case .read: "doc.text.magnifyingglass"
        case .click: "hand.tap"
        case .type: "keyboard"
        case .select: "list.bullet"
        case .scroll: "arrow.up.and.down"
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .reload: "arrow.clockwise"
        case .evaluate: "curlybraces"
        case .screenshot: "camera.viewfinder"
        case nil: "cursorarrow.motionlines"
        }
    }

    private var title: LocalizedStringKey {
        switch action {
        case .open: "智能体正在打开网页"
        case .read: "智能体正在读取页面"
        case .click: "智能体正在点击"
        case .type: "智能体正在输入"
        case .select: "智能体正在选择"
        case .scroll: "智能体正在滚动页面"
        case .back: "智能体正在后退"
        case .forward: "智能体正在前进"
        case .reload: "智能体正在刷新"
        case .evaluate: "智能体正在运行脚本"
        case .screenshot: "智能体正在截图"
        case nil: "智能体正在操作网页"
        }
    }
}

private extension View {
    /// The system's glass from iOS 26; before, its thick material with a soft shadow.
    @ViewBuilder
    func agentStatusSurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}
