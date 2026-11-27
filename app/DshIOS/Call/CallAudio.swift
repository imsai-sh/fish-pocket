import AVFoundation
import UIKit

/// The call's sound: one audio engine for both directions. The microphone stays open while the
/// reply plays; WebRTC's echo canceller (`CallEchoCanceller`) takes the reply out of it, with what
/// was placed on the speaker as the reference. The system's call audio processing is off: on an
/// iPhone's speaker its echo cancelling lets the start of each call through, and recognition then
/// hears her own words. The microphone comes out as 16 kHz mono 16-bit PCM in 200 ms packets;
/// replies go in as 24 kHz mono 16-bit PCM and play as they arrive.
///
/// The reply is played the way a browser's audio context plays it (`CallSpeaker`): every 20 ms
/// the next bit, up to half a second, is placed on the speaker's clock, at most half a second
/// ahead, and the same samples at the same position go to the canceller. The rest waits here,
/// where cutting in drops it.
///
/// The engine is started, rebuilt after a route change and stopped on its own queue; the reply
/// and the canceller live on another; the callbacks come from those and the audio threads.
final class CallAudio: @unchecked Sendable {
    static let chunkBytes = 6_400

    /// Why the call cannot go on.
    enum Halt: Sendable {
        /// Another app took the audio (a phone call, FaceTime, an alarm) and it could not be
        /// taken back when that ended.
        case interrupted
        case failed(String)
    }

    /// A packet of the microphone. Not called while muted.
    var onChunk: (@Sendable (Data) -> Void)?
    /// The microphone's level, 0…1, about twenty times a second (0 while muted).
    var onInputLevel: (@Sendable (Float) -> Void)?
    /// The reply's level as it is heard, 0…1.
    var onOutputLevel: (@Sendable (Float) -> Void)?
    /// A buffer queued by `play` was heard to its end.
    var onPlayed: (@Sendable (_ tag: Int) -> Void)?
    /// The first audible sample of an idle reminder reached the output.
    var onReminderStarted: (@Sendable (_ reply: Int) -> Void)?
    /// Whether the sound now comes out of the phone's own speaker (headphones and Bluetooth say no).
    var onRoute: (@Sendable (_ speaker: Bool, _ external: Bool) -> Void)?
    var onHalt: (@Sendable (Halt) -> Void)?
    /// The system took the audio for a while (true) or gave it back (false): the call waits
    /// in between, neither hearing nor playing.
    var onPause: (@Sendable (Bool) -> Void)?

    /// Half a second at the speaker's rate: the most placed at once, and the most placed ahead.
    private static let ahead = CallSpeaker.rate / 2

    private let engine = AVAudioEngine()
    private let speaker = CallSpeaker()
    private let queue = DispatchQueue(label: "call.audio", qos: .userInteractive)
    /// The reply on its way to the speaker, and the echo canceller.
    private let stream = DispatchQueue(label: "call.stream", qos: .userInteractive)
    private let lock = NSLock()
    private let echo = CallEchoCanceller()
    /// The microphone to the canceller's 16 kHz mono.
    private var micConverter: AVAudioConverter?
    private var pending = Data()
    private var muted = false
    private var running = false
    /// Between an interruption's start and end: the engine is stopped, the call is not.
    private var paused = false
    /// A byte left over from a piece that split a sample.
    private var carry: UInt8?
    private var wantsSpeaker = true
    private var lastInputLevel: TimeInterval = 0
    private var lastOutputLevel: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    // On `stream`: the reply not yet placed on the speaker, and the tags of `play` waiting
    // to be heard. A tag's offset counts the samples queued up to its piece's end; once that
    // sample is placed, its position on the speaker's clock, and the tag is reported once the
    // clock has passed it by the output's latency.
    private var reply: [Float] = []
    private var queued = 0
    private var placed = 0
    /// Where the last placed piece ends on the speaker's clock.
    private var cursor = 0
    private var unplaced: [(tag: Int, offset: Int)] = []
    private var unheard: [(tag: Int, end: Int)] = []
    /// The first non-silent sample of a reminder, in the queue and then on the speaker's clock.
    private var reminderPlayback: (id: Int, offset: Int, start: Int?, started: Bool)?
    /// Samples between being rendered and being heard.
    private var outputDelay = 0
    private var pump: DispatchSourceTimer?
    /// A test file stands in for the microphone (`DSH_CALL_AUDIO`, debug builds only).
    private var feeding = false
    #if DEBUG
    private var feed: DispatchSourceTimer?
    #endif

    // MARK: Lifecycle

    func start() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configureSession()
                    try self.build()
                    self.observe()
                    self.running = true
                    self.reportRoute()
                    self.startPump()
                    done.resume()
                } catch {
                    self.teardown()
                    done.resume(throwing: error)
                }
            }
        }
        #if DEBUG
        queue.async { self.startFeed() }
        #endif
    }

    func stop() {
        queue.async {
            guard self.running else { return }
            self.running = false
            self.teardown()
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.default`, not `.voiceChat`: no system call processing in front of the echo canceller.
        // Bluetooth headsets with a microphone (HFP) count as a way to talk.
        // Started like a phone call: activating a session that does not mix stops whatever was
        // playing (music would otherwise go into the microphone, and the echo canceller only
        // knows her voice). Then it turns mixable, so audio the user starts in another app during
        // the call plays alongside instead of interrupting it, as in a WeChat call. What stopped
        // at the start resumes at hang-up (`notifyOthersOnDeactivation`).
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
        applySpeaker()
    }

    private func build() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        micConverter = nil
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.heard(buffer)
        }
        if engine.attachedNodes.contains(speaker.node) == false { engine.attach(speaker.node) }
        engine.connect(speaker.node, to: engine.mainMixerNode, format: speaker.format)
        let session = AVAudioSession.sharedInstance()
        let latency = session.outputLatency + session.ioBufferDuration
        stream.async { self.outputDelay = Int(latency * Double(CallSpeaker.rate)) }
        let route = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        CallDiagnostics.note(String(format: "audio built: mode %@, system processing %@, mic %.0f Hz %d ch, route %@, output latency %.0f ms",
                                    session.mode.rawValue, "\(input.isVoiceProcessingEnabled)", format.sampleRate, Int(format.channelCount), route, latency * 1000))
        engine.prepare()
        try engine.start()
    }

    private func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        #if DEBUG
        feed?.cancel()
        feed = nil
        #endif
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { pending = Data(); carry = nil; feeding = false }
        stream.async {
            self.pump?.cancel()
            self.pump = nil
            self.dropReply()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Plugging in headphones or a Bluetooth headset reconfigures the engine: it stops, and
    /// starts again here with the new route. The speaker's clock stops with it and goes on from
    /// where it was, with what was placed on it.
    private func rebuild() {
        guard running, !paused else { return }
        CallDiagnostics.note("audio configuration changed: rebuilding")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try build()
            reportRoute()
        } catch {
            running = false
            teardown()
            onHalt?(.failed(error.localizedDescription))
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                guard let type, let self else { return }
                let began = type == .began
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
                let shouldResume = options?.contains(.shouldResume) ?? false
                self.queue.async { began ? self.pause() : self.resume(allowed: shouldResume) }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.rebuild() }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard self.running else { return }
                    // A headset taking over: the speaker override would send the sound past it.
                    if self.externalRoute { self.lock.withLock { self.wantsSpeaker = false } }
                    self.applySpeaker()
                    self.reportRoute()
                }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard self.running else { return }
                    self.running = false
                    self.teardown()
                    self.onHalt?(.failed(String(localized: "系统音频服务重启了")))
                }
            },
        ]
    }

    /// An interruption began. Mixing with other apps keeps their sound from interrupting the
    /// call; what still does is a phone call, FaceTime, Siri or an alarm. The call waits for it
    /// to end instead of hanging up: the reply stays where it was, on the speaker's stopped clock.
    private func pause() {
        guard running, !paused else { return }
        paused = true
        CallDiagnostics.note("audio interrupted: pausing")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { pending = Data() }
        onInputLevel?(0)
        stream.async { self.onOutputLevel?(0) }
        onPause?(true)
    }

    /// The interruption ended. The audio comes back only when the system says so
    /// (`shouldResume`, as after a phone call or Siri). Without it the user moved on to other
    /// audio on purpose, and the call ends as it used to; so it does when taking the audio back fails.
    private func resume(allowed: Bool) {
        guard running, paused else { return }
        paused = false
        guard allowed else {
            CallDiagnostics.note("interruption ended without shouldResume: hanging up")
            running = false
            teardown()
            onHalt?(.interrupted)
            return
        }
        CallDiagnostics.note("interruption ended: resuming")
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            applySpeaker()
            try build()
            reportRoute()
            onPause?(false)
        } catch {
            CallDiagnostics.note("could not resume: \(error.localizedDescription)")
            running = false
            teardown()
            onHalt?(.interrupted)
        }
    }

    // MARK: Controls

    func setMuted(_ value: Bool) {
        lock.withLock {
            muted = value
            if value { pending = Data() }
        }
        if value { onInputLevel?(0) }
    }

    /// The phone's own speaker, or the earpiece. A headset, when one is connected, wins either way.
    func setSpeaker(_ on: Bool) {
        queue.async {
            self.lock.withLock { self.wantsSpeaker = on }
            guard self.running else { return }
            self.applySpeaker()
            self.reportRoute()
        }
    }

    private func applySpeaker() {
        let speaker = lock.withLock { wantsSpeaker } && !externalRoute
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    private var externalRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .carAudio, .usbAudio, .lineOut].contains(output.portType)
        }
    }

    private func reportRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        onRoute?(outputs.contains { $0.portType == .builtInSpeaker }, externalRoute)
    }

    // MARK: Playback

    /// Queue 24 kHz mono 16-bit PCM; `tag` comes back through `onPlayed` once it has been heard.
    func play(_ pcm: Data, tag: Int, reminder: Int?) {
        let samples = lock.withLock { () -> [Float] in
            var bytes = [UInt8](pcm)
            if let carry { bytes.insert(carry, at: 0) }
            carry = bytes.count % 2 == 1 ? bytes.removeLast() : nil
            return (0..<bytes.count / 2).map { index in
                Float(Int16(bitPattern: UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8)) / 32_768
            }
        }
        stream.async {
            if let reminder, self.reminderPlayback?.id != reminder,
               let first = samples.firstIndex(where: { $0 != 0 }) {
                self.reminderPlayback = (reminder, self.queued + first, nil, false)
            }
            self.reply.append(contentsOf: samples)
            self.queued += samples.count
            self.unplaced.append((tag, self.queued))
            self.pumpReply()
        }
    }

    func hasStartedReminder(_ id: Int) -> Bool {
        stream.sync { heardReminder(id, rendered: speaker.clock) }
    }

    /// Drop queued audio on interruption. If a reminder is pending, check it at the cut so
    /// the caller can record it even when the playback notification is still on its way.
    func flush(reminder: Int?) -> Bool {
        lock.withLock { carry = nil }
        let cut: @Sendable () -> Bool = { [self] in
            let heard = dropReply(reminder: reminder)
            onOutputLevel?(0)
            return heard
        }
        if reminder != nil { return stream.sync(execute: cut) }
        stream.async { _ = cut() }
        return false
    }

    private func heardReminder(_ id: Int, rendered: Int) -> Bool {
        guard let reminderPlayback, reminderPlayback.id == id else { return false }
        if reminderPlayback.started { return true }
        guard let start = reminderPlayback.start else { return false }
        return start < rendered - outputDelay
    }

    /// Silences what is placed and not played, takes it out of the canceller's reference (what
    /// already played stays there, for its echo), and forgets the rest of the reply.
    @discardableResult
    private func dropReply(reminder: Int? = nil) -> Bool {
        let now = speaker.cut()
        let heard = reminder.map { heardReminder($0, rendered: now) } ?? false
        echo?.truncatePlayback(at: now)
        cursor = now
        reply = []
        queued = 0
        placed = 0
        unplaced = []
        unheard = []
        reminderPlayback = nil
        return heard
    }

    private func startPump() {
        stream.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.stream)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.pumpReply() }
            self.pump = timer
            timer.resume()
        }
    }

    /// Every 20 ms, and whenever a piece arrives: reports what has been heard, places the next
    /// bit of the reply on the speaker and hands the same samples to the canceller.
    private func pumpReply() {
        let now = speaker.clock
        if let reminderPlayback, !reminderPlayback.started, heardReminder(reminderPlayback.id, rendered: now) {
            self.reminderPlayback?.started = true
            onReminderStarted?(reminderPlayback.id)
        }
        while let first = unheard.first, first.end <= now - outputDelay {
            unheard.removeFirst()
            onPlayed?(first.tag)
        }
        if !reply.isEmpty, cursor - now < Self.ahead {
            let piece = Array(reply.prefix(Self.ahead))
            reply.removeFirst(piece.count)
            let start = speaker.place(piece, notBefore: cursor)
            echo?.addPlayback(piece, at: start)
            let first = placed
            placed += piece.count
            cursor = start + piece.count
            if let reminderPlayback, reminderPlayback.start == nil, reminderPlayback.offset < placed {
                self.reminderPlayback?.start = start + reminderPlayback.offset - first
            }
            while let tag = unplaced.first, tag.offset <= placed {
                unplaced.removeFirst()
                unheard.append((tag.tag, start + max(0, tag.offset - first)))
            }
        }
        // Pieces without a whole sample end where everything placed so far does.
        while reply.isEmpty, let tag = unplaced.first, tag.offset <= placed {
            unplaced.removeFirst()
            unheard.append((tag.tag, cursor))
        }
        let time = ProcessInfo.processInfo.systemUptime
        if time - lastOutputLevel >= 0.05, let rms = speaker.takeRMS() {
            lastOutputLevel = time
            onOutputLevel?(Self.level(rms: rms))
        }
    }

    // MARK: Taps

    /// The raw microphone, to the canceller, with the speaker's clock as it arrived. It keeps
    /// hearing while muted, so the canceller follows the call; only what goes to recognition stops.
    private func heard(_ buffer: AVAudioPCMBuffer) {
        let played = speaker.clock
        guard !lock.withLock({ feeding }) else { return }
        guard let converter = Self.converter(&micConverter, for: buffer) else { return }
        let samples = Self.convert(buffer, with: converter)
        stream.async {
            guard let echo = self.echo else { return self.cleaned(samples) }
            self.cleaned(echo.process(samples, played: played))
        }
    }

    /// The microphone with her voice taken out: what recognition hears and the call shows as the user's level.
    private func cleaned(_ frame: [Float]) {
        guard !lock.withLock({ muted }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastInputLevel >= 0.05 {
            lastInputLevel = now
            onInputLevel?(Self.level(frame))
        }
        var data = Data(count: frame.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for (index, value) in frame.enumerated() {
                samples[index] = Int16(max(-1, min(1, value)) * 32_767)
            }
        }
        emit(data)
    }

    /// The converter for this piece's format: the engine can hand over another format than the one
    /// it reported when the tap went in, and a converter fed the wrong format gives nothing.
    private static func converter(_ converter: inout AVAudioConverter?, for buffer: AVAudioPCMBuffer) -> AVAudioConverter? {
        if let converter, converter.inputFormat == buffer.format { return converter }
        CallDiagnostics.note("microphone to the echo canceller: \(buffer.format.sampleRate) Hz \(buffer.format.channelCount) ch")
        converter = AVAudioConverter(from: buffer.format, to: CallEchoCanceller.captureFormat)
        converter?.downmix = true
        return converter
    }

    /// One piece through a converter that keeps its state from piece to piece.
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float] {
        let target = converter.outputFormat
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var given = false
        converter.convert(to: out, error: nil) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let samples = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: samples[0], count: Int(out.frameLength)))
    }

    private func emit(_ data: Data) {
        let chunks = lock.withLock { () -> [Data] in
            pending.append(data)
            var chunks: [Data] = []
            while pending.count >= Self.chunkBytes {
                chunks.append(pending.prefix(Self.chunkBytes))
                pending.removeFirst(Self.chunkBytes)
            }
            return chunks
        }
        chunks.forEach { onChunk?($0) }
    }

    private static func level(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return level(rms: (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot())
    }

    /// RMS in dB, -50…-10 mapped to 0…1.
    private static func level(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(max((decibels + 50) / 40, 0), 1)
    }

    // MARK: Testing

    #if DEBUG
    /// `DSH_CALL_AUDIO=<16 kHz mono WAV>`: the call hears that file, in real time, instead of the
    /// microphone, then silence. The simulator's microphone is the Mac's, which cannot be fed.
    private func startFeed() {
        guard let path = ProcessInfo.processInfo.environment["DSH_CALL_AUDIO"], !path.isEmpty,
              let data = FileManager.default.contents(atPath: path) else { return }
        let pcm = Self.wavPCM(data)
        var offset = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.running, !self.lock.withLock({ self.muted }) else { return }
            let chunk: Data
            if offset < pcm.count {
                chunk = pcm.subdata(in: offset..<min(offset + Self.chunkBytes, pcm.count))
                offset += Self.chunkBytes
            } else {
                chunk = Data(count: Self.chunkBytes)
            }
            self.onInputLevel?(Self.level(int16: chunk))
            self.onChunk?(chunk)
        }
        feed = timer
        lock.withLock { feeding = true }
        timer.resume()
    }

    /// The same scale as `level(_:)`, for 16-bit samples.
    private static func level(int16 data: Data) -> Float {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sum: Float = 0
        data.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) {
                let value = Float(sample) / 32_768
                sum += value * value
            }
        }
        let decibels = 20 * log10(max((sum / Float(count)).squareRoot(), 1e-7))
        return min(max((decibels + 50) / 40, 0), 1)
    }

    private static func wavPCM(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var index = 12
        while index + 8 <= bytes.count {
            let id = String(bytes: bytes[index..<index + 4], encoding: .ascii)
            let size = Int(bytes[index + 4]) | Int(bytes[index + 5]) << 8 | Int(bytes[index + 6]) << 16 | Int(bytes[index + 7]) << 24
            if id == "data" { return Data(bytes[(index + 8)..<min(bytes.count, index + 8 + size)]) }
            index += 8 + size + (size & 1)
        }
        return Data()
    }
    #endif
}
