import SwiftUI

struct ContentPolicyNotice: View {
    let id: String
    let text: String
    let requestID: String?
    let model: SessionModel
    @Environment(AppModel.self) private var app
    @Environment(\.botComposer) private var chat
    @State private var editing = false
    @State private var sending = false
    @State private var question = ""
    @State private var lastAttempt: (text: String, id: String)?

    var body: some View {
        VStack(spacing: 10) {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(Palette.removed)
            if let requestID {
                Button {
                    UIPasteboard.general.string = requestID
                    Haptics.success()
                } label: {
                    Label(requestID, systemImage: "doc.on.doc").font(.caption.monospaced())
                }
                .accessibilityLabel("复制请求号")
                .accessibilityValue(requestID)
            }
            if case .bot(let botID) = chat, model.items.last?.id == id,
               app.botTeam.bot(botID)?.sessionId == model.sessionId {
                Button("开始新话题") { editing = true }
                    .buttonStyle(.capsule(.outline, height: 44, fill: false))
                    .disabled(sending || model.running || app.botTeam.isWorking(botID))
                    .sheet(isPresented: $editing) {
                        NavigationStack {
                            Form {
                                Section {
                                    TextField("新话题的第一句话", text: $question, axis: .vertical)
                                } footer: {
                                    Text("此前的聊天内容不会带入新话题。")
                                }
                            }
                            .navigationTitle("开始新话题")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("发送") { start(botID) }
                                        .disabled(sending || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }
                        .presentationDetents([.medium, .large])
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func start(_ botID: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        let attempt = lastAttempt.flatMap { $0.text == text ? $0.id : nil } ?? UUID().uuidString.lowercased()
        lastAttempt = (text, attempt)
        sending = true
        Task {
            defer { sending = false }
            do {
                try await app.botTeam.startNewTopic(botID: botID, sessionID: model.sessionId, text: text, requestID: attempt)
                editing = false
            } catch {
                app.showToast(error.localizedDescription, tone: .warning)
            }
        }
    }
}
