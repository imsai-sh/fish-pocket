import SwiftUI

/// A turn ended while the user was away: the fish says so in its own words.
/// What to do next is decided on the phone, where the result can be read.
struct CompletionView: View {
    let card: WatchModel.Card
    @Environment(\.dismiss) private var dismiss

    /// What the fish says, one at random each time.
    static let lines: [LocalizedStringKey] = [
        "跑完啦，快来看看～",
        "搞定！没让你等太久吧？",
        "活干完了，夸我。",
        "收工！今天也很能干。",
        "做好了，说是你写的也行。",
        "完成～我去喝口水。",
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                FishView(mood: .done).frame(width: 64, height: 64)
                Text(Self.lines[card.line])
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(card.completion.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if card.others > 0 {
                    Text("还有 \(card.others) 个会话也跑完了")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("好的") { dismiss() }
                    .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
    }
}
