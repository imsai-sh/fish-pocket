import AVFoundation
import SwiftUI

/// 设置 → 语音: which service recognizes hold-to-talk, and the voice replies are read in. DeepSeek uses the key or account the
/// models already use; Volcengine (豆包语音) takes the user's own API Key: how to get one, where
/// it goes, and a check that it works. Also the sheet the microphone button opens when
/// Volcengine is chosen without a key; `onReady` then runs once a working service is set up.
struct VoiceSettingsPage: View {
    var onReady: (() -> Void)?
    @State private var speech = VolcSpeech.shared
    @State private var preferences = VoicePreferences.shared
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
                Text("按住输入栏说话，松手把识别出的文字发出去。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

            Section {
                Picker("识别服务", selection: $preferences.source) {
                    ForEach(VoicePreferences.Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerValueTint()
            } header: {
                Text("语音输入")
            } footer: {
                switch preferences.source {
                case .deepseek:
                    Text("用你在「模型」里填写的 DeepSeek API Key，没有 Key 时用登录的 DeepSeek 账号（DeepSeek 目前还不支持账号登录使用语音），费用由 DeepSeek 按录音时长收取。松手后整段识别，说话时不显示文字。录音直接发给 DeepSeek 识别，App 不保存录音。")
                case .volcengine:
                    Text("说话时文字就会出现。需要你自己开通火山引擎的豆包语音并填写 API Key，费用由火山引擎按你的用量收取。API Key 只保存在这台设备本地，只用来连接火山引擎，不会上传到其他任何地方。")
                }
            }
            .groupedRow()
            .onChange(of: preferences.source) { status = nil }

            if preferences.source == .deepseek {
                Section {
                    Button { checkDeepSeek() } label: {
                        HStack(spacing: 8) {
                            if checking { ProgressView().tint(Palette.onInk) }
                            Text("测试连接")
                        }
                    }
                    .buttonStyle(.capsule(height: 50))
                    .disabled(checking)
                } footer: {
                    statusFooter
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } else {
                volcengine
            }

            Section {
                Picker("声音", selection: $preferences.readingVoice) {
                    ForEach(DeepSeekSpeech.Voice.allCases) { Text($0.title).tag($0) }
                }
                .pickerValueTint()
                Button("试听") {
                    ReadAloud.shared.stop()
                    ReadAloud.shared.enqueue(String(localized: "你好，我会用这个声音为你朗读。"))
                }
            } header: {
                Text("朗读")
            } footer: {
                Text("朗读回复和 Agent 念出来的话都用 DeepSeek 的声音，同样用「模型」里的 DeepSeek API Key，费用由 DeepSeek 按字数收取。")
            }
            .groupedRow()
            .onChange(of: preferences.readingVoice) { ReadAloud.shared.stop() }
        }
        .groupedList()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("语音")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var statusFooter: some View {
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

    @ViewBuilder
    private var volcengine: some View {
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
            statusFooter
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

    /// Half a second of silence through DeepSeek: an empty answer means the key works.
    private func checkDeepSeek() {
        Haptics.tap()
        checking = true
        status = nil
        Task {
            do {
                _ = try await DeepSeekSpeech.transcribe(wav: DeepSeekSpeech.wave(pcm: Data(count: 16_000), sampleRate: 16_000))
                passed()
            } catch {
                status = .failed(error.localizedDescription)
                Haptics.error()
            }
            checking = false
        }
    }

    private func passed() {
        status = .passed
        Haptics.success()
        if let onReady {
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                onReady()
            }
        }
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
                passed()
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
