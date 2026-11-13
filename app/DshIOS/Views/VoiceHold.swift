import SwiftUI

/// The middle of the composer in voice mode: 按住说话. Holding turns it into the live
/// waveform; moving up past `cancelDistance` arms the cancel, letting go sends or cancels.
struct HoldToTalk: View {
    let voice: VoiceInput
    let begin: () -> Void
    let release: () -> Void
    /// Up from where the finger went down, past the bar's top edge to the ✕ above it.
    static let cancelDistance: CGFloat = 64

    var body: some View {
        ZStack {
            switch voice.phase {
            case .idle:
                Text("按住说话").font(.callout.weight(.semibold)).foregroundStyle(Palette.ink)
            case .listening:
                VoiceWaveform(levels: voice.levels, color: Palette.onInk)
                    .frame(height: 26)
                    .padding(.horizontal, 4)
            case .finishing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Palette.secondary)
                    Text("正在识别…").font(.callout).foregroundStyle(Palette.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .overlay {
            HoldPress(
                began: begin,
                moved: { lift in
                    let armed = lift > Self.cancelDistance
                    guard armed != voice.cancelArmed, voice.holding else { return }
                    // Only a faint tap saying the cancel area is reached; nothing on the way back.
                    // A rich buzz here makes cancelling feel rewarding, as if it were the thing to do.
                    if armed { Haptics.soft() }
                    voice.track(armed: armed)
                },
                ended: release
            )
        }
        .accessibilityElement()
        .accessibilityLabel("按住说话")
        .accessibilityHint("松手发送，上移取消")
        .accessibilityAddTraits(.isButton)
    }
}

/// The hold itself, as a UIKit long press that begins the moment the finger lands. A SwiftUI
/// gesture this close to the bottom of the screen hears of the touch about 0.75 s late on a
/// device (measured: 780 ms there, 99 ms mid-screen; this recognizer 32 ms at the bottom).
private struct HoldPress: UIViewRepresentable {
    let began: () -> Void
    /// How far the finger is above where it went down.
    let moved: (CGFloat) -> Void
    /// Let go, or the touch was taken away (a call, a system gesture).
    let ended: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        recognizer.minimumPressDuration = 0
        recognizer.allowableMovement = .greatestFiniteMagnitude
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: HoldPress
        private var start: CGFloat = 0
        init(parent: HoldPress) { self.parent = parent }

        @objc func changed(_ recognizer: UILongPressGestureRecognizer) {
            let y = recognizer.location(in: nil).y
            switch recognizer.state {
            case .began:
                start = y
                parent.began()
            case .changed:
                parent.moved(start - y)
            case .ended, .cancelled, .failed:
                parent.ended()
            default:
                break
            }
        }
    }
}

/// Bars for the latest input levels: the newest in the middle, older ones outward on both
/// sides, so a sound shows at once and the shape is whole from the first moment. Silence
/// still draws every bar, short.
struct VoiceWaveform: View {
    let levels: [Float]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let count = levels.count
            let spacing: CGFloat = 3
            let width = max(2, (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let floor = min(8, proxy.size.height)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: min(width, 4), height: max(floor, proxy.size.height * CGFloat(level(at: index))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.linear(duration: 0.08), value: levels)
        }
        .accessibilityHidden(true)
    }

    /// Bar `index` shows the sample as old as its distance from the middle.
    private func level(at index: Int) -> Float {
        let half = levels.count / 2
        let distance = index < half ? half - 1 - index : index - half
        return levels[max(0, levels.count - 1 - distance)]
    }
}

/// Over the conversation while the bar is held: what has been heard so far, and the ✕ the
/// finger moves up onto to cancel. It takes no touches: the hold stays with the bar.
struct VoiceHoldOverlay: View {
    let voice: VoiceInput

    var body: some View {
        ZStack(alignment: .bottom) {
            if voice.holding {
                Rectangle().fill(.regularMaterial).ignoresSafeArea(edges: .top)
                    .transition(.opacity)
                VStack(spacing: 22) {
                    transcript
                    cancelTarget
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
                .readableWidth()
                .transition(.opacity)
            }
        }
        // Pressing answers at once; only letting go eases out.
        .animation(voice.holding ? .easeOut(duration: 0.08) : .snappy(duration: 0.2), value: voice.holding)
        .animation(.snappy(duration: 0.18), value: voice.cancelArmed)
        .allowsHitTesting(false)
    }

    /// The running transcript as the message it will become, right-aligned like the user's own.
    /// A long one keeps its latest lines.
    private var transcript: some View {
        Group {
            if voice.transcript.isEmpty {
                Text("正在听…").foregroundStyle(Palette.secondary)
            } else {
                Text(voice.transcript).foregroundStyle(Palette.ink)
            }
        }
        .font(.body)
        .lineLimit(8)
        .truncationMode(.head)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .opacity(voice.cancelArmed ? 0.35 : 1)
    }

    private var cancelTarget: some View {
        VStack(spacing: 10) {
            Image(systemName: "xmark")
                .font(.system(size: voice.cancelArmed ? 26 : 22, weight: .semibold))
                .foregroundStyle(voice.cancelArmed ? .white : Palette.ink)
                .frame(width: voice.cancelArmed ? 76 : 60, height: voice.cancelArmed ? 76 : 60)
                .background(voice.cancelArmed ? Color.red : Palette.control, in: Circle())
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Group {
                    if voice.cancelArmed {
                        Text("松手取消").foregroundStyle(Color.red)
                    } else if let left = voice.secondsLeft(at: context.date) {
                        Text("\(left) 秒后自动发送").foregroundStyle(Palette.ink)
                    } else {
                        Text("松手发送，上移取消").foregroundStyle(Palette.secondary)
                    }
                }
                .font(.footnote.weight(.medium))
                .monospacedDigit()
            }
        }
        .frame(height: 106, alignment: .bottom)
    }
}

