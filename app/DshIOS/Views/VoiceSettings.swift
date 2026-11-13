import AVFoundation
import SwiftUI

/// 设置 → 语音输入: hold-to-talk runs on the user's own Volcengine (豆包语音) API Key. How to get
/// one, where it goes, and a check that it works. Also the sheet the microphone button opens
/// when no key is saved yet; `onReady` then runs once a working key is saved.
struct VoiceSettingsPage: View {
    var onReady: (() -> Void)?
    @State private var speech = VolcSpeech.shared
    @State private var draft = ""
    @State private var checking = false
    @State private var status: Status?

    private enum Status: Equatable {
        case passed
        case failed(String)
    }

    var body: some View {
        List {
            Section {
                Text("按住输入栏说话，松手把识别出的文字发出去。识别用的是火山引擎的豆包语音，需要你自己开通并填写 API Key，费用由火山引擎按你的用量收取。\n\nAPI Key 只保存在这台设备本地，只用来连接火山引擎，不会上传到其他任何地方。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

            // The key comes first, in the top half of the page, where the keyboard never covers it.
            Section {
                if let key = speech.key, !key.isEmpty {
                    LabeledContent("API Key") {
                        Text(verbatim: Self.masked(key)).monospaced().foregroundStyle(.secondary)
                    }
                    Button("删除 Key", role: .destructive) {
                        speech.removeKey()
                        status = nil
                    }
                } else {
                    HStack(spacing: 10) {
                        SecureField("粘贴或输入 API Key", text: $draft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { use(draft) }
                        // The system's paste button: one tap fills the key in and checks it, without a paste prompt.
                        PasteButton(payloadType: String.self) { strings in
                            guard let text = strings.first else { return }
                            Task { @MainActor in use(text) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                        .tint(Palette.ink)
                    }
                }
                Picker("计费方式", selection: $speech.resource) {
                    ForEach(VolcSpeech.Resource.allCases) { Text($0.title).tag($0) }
                }
                .pickerValueTint()
            } header: {
                Text("火山引擎")
            } footer: {
                Text("识别用的是豆包流式语音识别模型 2.0。计费方式要和你在控制台开通的一致，没特别选过就用「小时版」。录音直接发给火山引擎识别，App 不保存录音。")
            }
            .groupedRow()
            .onChange(of: speech.resource) { status = nil }

            Section {
                Button {
                    if speech.configured { check() } else { use(draft) }
                } label: {
                    HStack(spacing: 8) {
                        if checking { ProgressView().tint(Palette.onInk) }
                        Text(speech.configured ? "测试连接" : "保存并测试")
                    }
                }
                .buttonStyle(.capsule(height: 50))
                .disabled(checking || !speech.configured && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                switch status {
                case .passed:
                    Label("连接成功，可以按住说话了", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity)
                case .failed(let message):
                    Text(message).foregroundStyle(.red).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                case nil:
                    EmptyView()
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if !speech.configured {
                Section {
                    step(1, "登录火山引擎的豆包语音控制台，没有账号先注册并完成实名认证。")
                    step(2, "开通「豆包流式语音识别模型 2.0」。")
                    step(3, "在「API Key 管理」里创建一个 Key 并复制，回到这里粘贴到上面。")
                    Link(destination: VolcSpeech.keysURL) {
                        Label("打开豆包语音控制台", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("还没有 API Key？")
                }
                .groupedRow()
            }
        }
        .groupedList()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("语音输入")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(Palette.onInk)
                .frame(width: 20, height: 20)
                .background(Palette.ink, in: Circle())
            Text(text).font(.subheadline)
        }
    }

    /// Save a pasted or typed key and check it.
    private func use(_ text: String) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        dismissKeyboard()
        speech.save(key: key)
        draft = ""
        check()
    }

    private func check() {
        guard let key = speech.key else { return }
        Haptics.tap()
        checking = true
        status = nil
        let resource = speech.resource
        Task {
            do {
                try await VolcSpeech.check(key: key, resource: resource)
                status = .passed
                Haptics.success()
                if let onReady {
                    try? await Task.sleep(for: .milliseconds(600))
                    onReady()
                }
            } catch {
                status = .failed(error.localizedDescription)
                Haptics.error()
            }
            checking = false
        }
    }

    /// The first and last four characters.
    private static func masked(_ key: String) -> String {
        guard key.count > 10 else { return String(repeating: "•", count: key.count) }
        return key.prefix(4) + "••••" + key.suffix(4)
    }
}

/// The microphone permission: asked for on the first press of the voice bar.
@MainActor
enum MicrophoneAccess {
    enum State { case granted, denied, undecided }

    static var state: State {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undecided
        }
    }

    static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
