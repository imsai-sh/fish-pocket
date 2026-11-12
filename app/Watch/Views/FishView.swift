import SwiftUI

/// 大肥鱼 acting out what the agent is doing: a spinning ring while it works, a
/// bounce and a badge while it waits on the user, a tick when it is done, asleep when idle.
struct FishView: View {
    let mood: WatchModel.Mood
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if moves {
            // Drawn from the clock rather than started by a state change: there is no
            // start to miss when the view appears or the app comes back.
            TimelineView(.animation) { context in
                Stage(mood: mood, time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            Stage(mood: mood, time: nil)
        }
    }

    /// Only while the app is in front on a lit display. The system stops drawing
    /// otherwise, and a spinner caught mid-turn would look stuck.
    private var moves: Bool {
        (mood == .running || mood == .waiting) && !dimmed && scenePhase == .active
    }

    private struct Stage: View {
        let mood: WatchModel.Mood
        /// nil: still. Nothing drawn then suggests motion.
        let time: TimeInterval?

        /// Where `time` is in a loop of `period` seconds, 0 ..< 1.
        private func cycle(_ period: Double) -> Double {
            time.map { ($0 / period).truncatingRemainder(dividingBy: 1) } ?? 0
        }

        /// The same loop as a smooth swing 0 → 1 → 0.
        private func swing(_ period: Double) -> Double {
            (1 - cos(2 * .pi * cycle(period))) / 2
        }

        private var tint: Color {
            switch mood {
            case .waiting: Color("StatusWaiting")
            case .running, .done: Color("StatusRunning")
            case .idle, .offline, .unknown: .gray
            }
        }

        private var away: Bool { mood == .offline || mood == .unknown }

        var body: some View {
            GeometryReader { proxy in
                let size = min(proxy.size.width, proxy.size.height)
                ZStack {
                    ring
                    Image("Mascot")
                        .resizable()
                        .scaledToFill()
                        .background(LinearGradient(colors: [Color(red: 0.86, green: 0.93, blue: 1), .white], startPoint: .top, endPoint: .bottom))
                        .clipShape(Circle())
                        .padding(size * 0.07)
                        .saturation(away ? 0 : mood == .idle ? 0.7 : 1)
                        .opacity(away ? 0.55 : 1)
                        .offset(y: lift * size)
                    badge
                        .font(.system(size: size * 0.17, weight: .bold))
                        .frame(width: size * 0.3, height: size * 0.3)
                        .background(mood == .idle ? Color.black : tint, in: Circle())
                        .overlay { if mood == .idle { Circle().strokeBorder(.gray.opacity(0.5), lineWidth: 1) } }
                        .foregroundStyle(mood == .idle ? Color.gray : Color.black)
                        .offset(x: size * 0.35, y: -size * 0.35)
                }
                .frame(width: size, height: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
        }

        /// The fish bobs while working and hops while waiting.
        private var lift: CGFloat {
            switch mood {
            case .waiting: 0.01 - 0.06 * swing(0.9)
            case .running: 0.015 - 0.03 * swing(2.4)
            default: 0
            }
        }

        @ViewBuilder private var ring: some View {
            switch mood {
            case .running:
                if time == nil {
                    Circle().stroke(tint.opacity(0.6), lineWidth: 3)
                } else {
                    Circle().stroke(tint.opacity(0.25), lineWidth: 3)
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(360 * cycle(1.4)))
                }
            case .waiting:
                Circle().stroke(tint, lineWidth: 3)
                if time != nil {
                    // A ripple that eases out and fades.
                    let spread = 1 - pow(1 - cycle(1.1), 2)
                    Circle().stroke(tint.opacity(0.6 * (1 - spread)), lineWidth: 2)
                        .scaleEffect(1 + 0.14 * spread)
                }
            case .done:
                Circle().stroke(tint, lineWidth: 3)
            case .idle, .offline, .unknown:
                Circle().stroke(tint.opacity(0.35), lineWidth: 2)
            }
        }

        @ViewBuilder private var badge: some View {
            switch mood {
            case .waiting:
                Image(systemName: "exclamationmark").scaleEffect(0.9 + 0.25 * swing(1.1))
            case .running: Image(systemName: "ellipsis")
            case .done: Image(systemName: "checkmark")
            case .idle: Image(systemName: "zzz")
            case .offline: Image(systemName: "iphone.slash")
            case .unknown: Image(systemName: "questionmark")
            }
        }
    }
}
