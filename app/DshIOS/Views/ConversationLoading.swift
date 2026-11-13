import SwiftUI

/// A conversation on its way: the shape of a chat filling the page (the user's bubbles on the right,
/// replies on the left), with a soft light passing over it. It shows only when loading takes a moment, so a
/// conversation that opens quickly never flashes it, and it fades out as the messages arrive.
struct ConversationLoading: View {
    /// The user's bubbles in a Bot's chat take the Bot's colour; the skeleton hints at it too.
    @Environment(\.userBubbleTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    /// How long a load may take before the skeleton appears.
    private static let grace: Duration = .milliseconds(250)

    var body: some View {
        rows
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .readableWidth()
            // The whole page, top to bottom, as a long chat would fill it; what runs past the
            // bottom is cut off rather than squeezed.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("正在加载对话")
            .task {
                try? await Task.sleep(for: Self.grace)
                withAnimation(.easeOut(duration: 0.25)) { shown = true }
            }
    }

    /// One stretch of a chat; repeated, it covers even an iPad held upright.
    private static let pattern: [Row] = [
        .bubble(0.52), .reply([1, 0.92, 0.6]), .bubble(0.38), .reply([0.96, 0.74]),
        .bubble(0.6), .reply([1, 0.88, 0.95, 0.5]), .bubble(0.3), .reply([0.9, 0.66]),
    ]

    private enum Row {
        case bubble(CGFloat)
        case reply([CGFloat])
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(0..<(Self.pattern.count * 3), id: \.self) { index in
                switch Self.pattern[index % Self.pattern.count] {
                case .bubble(let width): bubble(width: width)
                case .reply(let widths): reply(widths)
                }
            }
        }
        .modifier(Sweep(enabled: !reduceMotion))
    }

    private var fill: Color { (tint?.fill ?? Palette.bubble).opacity(tint == nil ? 1 : 0.28) }

    private func bubble(width: CGFloat) -> some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(fill)
                .frame(width: geometry.size.width * width)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 44)
    }

    private func reply(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                GeometryReader { geometry in
                    Capsule().fill(Palette.bubble).frame(width: geometry.size.width * width)
                }
                .frame(height: 12)
            }
        }
    }
}

/// A band of light moving across what it covers, over and over.
private struct Sweep: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let phase = (timeline.date.timeIntervalSinceReferenceDate / 1.6).truncatingRemainder(dividingBy: 1) * 1.8 - 0.4
                    LinearGradient(
                        colors: [.clear, Palette.background.opacity(0.55), .clear],
                        startPoint: UnitPoint(x: phase - 0.3, y: 0.3), endPoint: UnitPoint(x: phase + 0.3, y: 0.7)
                    )
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}
