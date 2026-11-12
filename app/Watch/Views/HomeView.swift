import SwiftUI

/// The one screen: the fish and what it is up to, the sessions that are waiting or
/// running, a few recent ones, and the balance. An approval opens from its row;
/// a finished turn arrives as a card on top.
struct HomeView: View {
    @Environment(WatchModel.self) private var model
    @State private var approving: WatchSnapshot.Session?
    /// Taps on the fish: each one makes it hop.
    @State private var pokes = 0

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: 8) {
                Button {
                    pokes += 1
                    model.poke()
                } label: {
                    FishView(mood: model.mood)
                        .frame(width: 92, height: 92)
                        .keyframeAnimator(initialValue: 1.0, trigger: pokes) { fish, scale in
                            fish.scaleEffect(scale)
                        } keyframes: { _ in
                            SpringKeyframe(1.12, duration: 0.14)
                            SpringKeyframe(1.0, duration: 0.3)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("刷新")
                .padding(.top, 4)
                VStack(spacing: 2) {
                    Text(headline).font(.headline)
                    Text(subline).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.bottom, 4)

                if let snapshot = model.snapshot, model.mood != .offline {
                    // Status unknown: what was running or waiting may no longer be, so nothing is shown as such.
                    let sessions = model.mood == .unknown ? snapshot.sessions.map(\.resting) : snapshot.sessions
                    let active = sessions.filter(\.phase.active)
                    let recent = sessions.filter { !$0.phase.active }.prefix(3)
                    ForEach(active) { session in
                        if session.approval != nil {
                            Button { approving = session } label: { SessionRow(session: session) }
                                .buttonStyle(.plain)
                        } else {
                            SessionRow(session: session)
                        }
                    }
                    if !recent.isEmpty {
                        Text("最近")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                            .padding(.leading, 4)
                        ForEach(recent) { SessionRow(session: $0) }
                    }
                    if let balance = snapshot.balance {
                        HStack {
                            Text("余额").foregroundStyle(.secondary)
                            Spacer()
                            Text(balance).monospacedDigit()
                        }
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .sheet(item: $approving) { ApprovalView(session: $0) }
        .sheet(item: $model.card) { CompletionView(card: $0) }
    }

    private var headline: LocalizedStringKey {
        switch model.mood {
        case .offline: "还没连上"
        case .unknown: "状态未知"
        case .waiting: "等你答复"
        case .running: "正在干活"
        case .idle, .done: "歇着呢"
        }
    }

    private var subline: LocalizedStringKey {
        switch model.mood {
        case .offline: "在 iPhone 上打开 Fish Pocket"
        case .unknown: "iPhone 上的 App 可能没在运行"
        case .waiting: "\(model.snapshot?.waiting.count ?? 0) 个会话在等你"
        case .running: "\(model.snapshot?.running.count ?? 0) 个会话在跑"
        case .idle, .done: "有事随时叫我"
        }
    }
}

private extension WatchSnapshot.Session {
    /// The same session with nothing going on.
    var resting: Self {
        var session = self
        session.phase = .idle
        session.detail = nil
        session.approval = nil
        session.since = nil
        return session
    }
}

private struct SessionRow: View {
    let session: WatchSnapshot.Session

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.footnote.weight(.medium)).lineLimit(1)
                switch session.phase {
                case .approval:
                    Text(session.detail ?? String(localized: "等你允许")).font(.caption2).foregroundStyle(tint).lineLimit(2)
                case .question:
                    if let detail = session.detail { Text(detail).font(.caption2).foregroundStyle(tint).lineLimit(2) }
                    Text("在 iPhone 上回答").font(.caption2).foregroundStyle(.secondary)
                case .running:
                    if let since = session.since {
                        Text(since, style: .timer).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                case .idle:
                    Text(session.updatedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if session.approval != nil {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var tint: Color {
        switch session.phase {
        case .approval, .question: Color("StatusWaiting")
        case .running: Color("StatusRunning")
        case .idle: .gray.opacity(0.6)
        }
    }
}
