import SwiftUI

/// A tool approval: which session asks, what for, and 拒绝 / 允许 always in reach.
struct ApprovalView: View {
    let session: WatchSnapshot.Session
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Label("等你允许", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color("StatusWaiting"))
                Text(session.title).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                if let detail = session.detail {
                    Text(detail)
                        .font(.system(.footnote, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 4)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button("拒绝") { answer(false) }
                    .buttonStyle(.bordered)
                    .tint(.red)
                Button("允许") { answer(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("StatusRunning"))
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .background(.black)
        }
    }

    private func answer(_ allow: Bool) {
        if let approval = session.approval { model.answer(approval, allow: allow) }
        dismiss()
    }
}
