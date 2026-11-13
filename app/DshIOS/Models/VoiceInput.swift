import Foundation
import Observation

/// Speech to text for hold-to-talk. The recognizer plugs in at `VoiceInput.makeTranscriber`;
/// the composer only sees the running text, the input level and the final text.
@MainActor
protocol SpeechTranscriber: AnyObject {
    /// Start listening. `partial` gets the whole running transcript each time it changes,
    /// `level` the input level (0…1) about twenty times a second, `failed` a failure while
    /// still listening (the connection dropped, the key was refused).
    func start(
        partial: @escaping @MainActor (String) -> Void,
        level: @escaping @MainActor (Float) -> Void,
        failed: @escaping @MainActor (Error) -> Void
    ) async throws
    /// Stop listening and return the final text.
    func finish() async throws -> String
    /// Stop and throw the recording away.
    func cancel()
}

/// Hold-to-talk in the composer: hold the bar to speak, let go to send, move up to cancel.
@MainActor
@Observable
final class VoiceInput {
    enum Phase: Equatable {
        case idle
        /// The finger is down and the recognizer is listening.
        case listening
        /// Let go: the recognizer is finishing the last words.
        case finishing
    }

    enum Outcome {
        case text(String)
        case cancelled
        case tooShort
        case empty
        case failed(String)
    }

    /// The bar shows 按住说话 in place of the text field.
    var mode = false
    private(set) var phase: Phase = .idle
    /// The finger has moved up into the cancel area: letting go throws the recording away.
    private(set) var cancelArmed = false
    private(set) var transcript = ""
    /// The latest input levels, oldest first: the waveform.
    private(set) var levels: [Float] = Array(repeating: 0, count: VoiceInput.barCount)
    private(set) var startedAt: Date?

    static let barCount = 32
    /// One recording at most this long; it then sends on its own, the finger still down.
    static let maxDuration: TimeInterval = 60
    /// Shorter than this is a tap, not speech.
    static let minDuration: TimeInterval = 0.6

    /// The service chosen in 设置 → 语音输入: DeepSeek with the models' key, or Volcengine with
    /// the user's own key (nil until one is saved).
    @ObservationIgnored var makeTranscriber: () -> SpeechTranscriber? = {
        #if DEBUG
        // Made-up levels and text, to look at the UI without a key or a microphone.
        if ProcessInfo.processInfo.arguments.contains("-dshVoiceDemo") { return DemoTranscriber() }
        #endif
        switch VoicePreferences.shared.source {
        case .deepseek:
            return DeepSeekTranscriber()
        case .volcengine:
            let speech = VolcSpeech.shared
            guard let key = speech.key, !key.isEmpty else { return nil }
            return VolcTranscriber(key: key, resource: speech.resource)
        }
    }

    /// A recognizer is set up: the microphone button goes straight to voice mode. DeepSeek counts
    /// as set up; a missing key shows as the press's error.
    static var ready: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-dshVoiceDemo") { return true }
        #endif
        return VoicePreferences.shared.source == .deepseek || VolcSpeech.shared.configured
    }
    @ObservationIgnored private var transcriber: SpeechTranscriber?
    @ObservationIgnored private var limit: Task<Void, Never>?

    var holding: Bool { phase == .listening }

    /// The finger went down. `reachedLimit` runs if the recording runs out of time while held,
    /// `failed` if recognition fails while held (the hold is then over).
    func begin(reachedLimit: @escaping @MainActor () -> Void, failed: @escaping @MainActor (String) -> Void) async -> String? {
        guard phase == .idle else { return nil }
        guard let transcriber = makeTranscriber() else { return String(localized: "语音输入还没有设置") }
        // The microphone and a reply being read do not share the audio session.
        ReadAloud.shared.stop()
        self.transcriber = transcriber
        transcript = ""
        levels = Array(repeating: 0, count: Self.barCount)
        cancelArmed = false
        startedAt = .now
        phase = .listening
        do {
            try await transcriber.start(
                partial: { [weak self] text in
                    guard let self, self.transcriber === transcriber, self.phase != .idle else { return }
                    self.transcript = text
                },
                level: { [weak self] value in
                    guard let self, self.transcriber === transcriber, self.phase == .listening else { return }
                    self.levels.removeFirst()
                    self.levels.append(min(max(value, 0), 1))
                },
                failed: { [weak self] error in
                    guard let self, self.transcriber === transcriber, self.phase == .listening else { return }
                    self.cancel()
                    failed(error.localizedDescription)
                }
            )
        } catch {
            reset()
            return error.localizedDescription
        }
        limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxDuration))
            guard !Task.isCancelled, let self, self.transcriber === transcriber, self.phase == .listening else { return }
            reachedLimit()
        }
        return nil
    }

    /// Where the finger is: above the bar by more than the cancel distance arms the cancel.
    func track(armed: Bool) {
        guard phase == .listening, armed != cancelArmed else { return }
        cancelArmed = armed
    }

    /// The finger came up (or the time ran out): send what was heard, unless cancel was armed.
    func release() async -> Outcome {
        guard phase == .listening, let transcriber else { return .cancelled }
        if cancelArmed {
            cancel()
            return .cancelled
        }
        if let startedAt, Date.now.timeIntervalSince(startedAt) < Self.minDuration {
            cancel()
            return .tooShort
        }
        phase = .finishing
        limit?.cancel()
        do {
            let text = try await transcriber.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            reset()
            return text.isEmpty ? .empty : .text(text)
        } catch {
            reset()
            return .failed(error.localizedDescription)
        }
    }

    /// Throw the recording away: cancel armed, the app left the foreground, the conversation closed.
    func cancel() {
        transcriber?.cancel()
        reset()
    }

    /// Seconds left before the recording sends on its own; nil while there is plenty.
    func secondsLeft(at date: Date) -> Int? {
        guard let startedAt, phase == .listening else { return nil }
        let left = Self.maxDuration - date.timeIntervalSince(startedAt)
        return left <= 10 ? max(0, Int(left.rounded(.up))) : nil
    }

    private func reset() {
        limit?.cancel()
        limit = nil
        transcriber = nil
        phase = .idle
        cancelArmed = false
        startedAt = nil
    }
}

#if DEBUG
/// For looking at the UI (`-dshVoiceDemo`): speech-like levels and a sentence typed out a few
/// characters a second. It does not use the microphone.
@MainActor
final class DemoTranscriber: SpeechTranscriber {
    private var task: Task<Void, Never>?
    private var text = ""
    private static let sample = Array("这是一段演示文字，用来查看按住说话的界面效果。")

    func start(
        partial: @escaping @MainActor (String) -> Void,
        level: @escaping @MainActor (Float) -> Void,
        failed: @escaping @MainActor (Error) -> Void
    ) async throws {
        task = Task { [weak self] in
            var tick = 0
            var envelope: Float = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                tick += 1
                // Bursts of syllables with short pauses between phrases.
                let speaking = tick % 36 < 28
                let target = speaking ? Float.random(in: 0.25...1) : Float.random(in: 0...0.08)
                envelope += (target - envelope) * 0.55
                level(envelope)
                if speaking, tick % 3 == 0, self.text.count < Self.sample.count {
                    self.text.append(Self.sample[self.text.count])
                    partial(self.text)
                }
            }
        }
    }

    func finish() async throws -> String {
        task?.cancel()
        try? await Task.sleep(for: .milliseconds(350))
        return text
    }

    func cancel() { task?.cancel() }
}
#endif
