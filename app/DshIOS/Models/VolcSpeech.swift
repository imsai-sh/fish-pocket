import AVFoundation
import Foundation
import Observation
import Security

/// Hold-to-talk through Volcengine's streaming recognition (豆包语音), on the user's own API Key.
/// The key stays in this device's keychain; audio goes straight from the phone to Volcengine.
@MainActor
@Observable
final class VolcSpeech {
    static let shared = VolcSpeech()

    /// The two-way streaming endpoint, optimized version: text comes back while the user speaks.
    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    static let consoleURL = URL(string: "https://console.volcengine.com/speech/new")!
    static let keysURL = URL(string: "https://console.volcengine.com/speech/new/setting/apikeys")!
    static let docsURL = URL(string: "https://www.volcengine.com/docs/6561/1354869")!

    /// How the key pays for the streaming recognition model 2.0 (the only model offered):
    /// by the hour or by concurrent streams.
    enum Resource: String, CaseIterable, Identifiable {
        case seedHourly = "volc.seedasr.sauc.duration"
        case seedConcurrent = "volc.seedasr.sauc.concurrent"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .seedHourly: String(localized: "小时版")
            case .seedConcurrent: String(localized: "并发版")
            }
        }
    }

    private static let resourceKey = "voiceVolcResource"

    /// The saved key, or nil.
    private(set) var key: String?
    var resource: Resource {
        didSet { UserDefaults.standard.set(resource.rawValue, forKey: Self.resourceKey) }
    }

    var configured: Bool { key?.isEmpty == false }

    private init() {
        key = VoiceKeychain.load()
        resource = UserDefaults.standard.string(forKey: Self.resourceKey).flatMap(Resource.init(rawValue:)) ?? .seedHourly
        #if DEBUG
        // Testing in the simulator without typing the key:
        // `SIMCTL_CHILD_DSH_VOICE_KEY=… xcrun simctl launch …` saves it.
        if let seeded = ProcessInfo.processInfo.environment["DSH_VOICE_KEY"], !seeded.isEmpty { save(key: seeded) }
        #endif
    }

    func save(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        VoiceKeychain.save(trimmed.isEmpty ? nil : trimmed)
        self.key = trimmed.isEmpty ? nil : trimmed
    }

    func removeKey() {
        VoiceKeychain.save(nil)
        key = nil
    }

    /// Whether Volcengine takes `key` for `resource`: connect, ask for a session, send a moment
    /// of silence. Throws what went wrong, worded for the user.
    nonisolated static func check(key: String, resource: Resource) async throws {
        let stream = VolcStream(key: key, resource: resource.rawValue)
        stream.send(audio: Data(count: MicCapture.chunkBytes), last: true)
        // A failure lands in the result too.
        let session = Task { try? await stream.open() }
        defer {
            session.cancel()
            stream.close()
        }
        _ = try await stream.result(timeout: .seconds(10))
    }
}

/// The key in the keychain: this device only, readable once it has been unlocked.
private enum VoiceKeychain {
    private static let service = "com.wsw.dsh-ios.voice-input"
    private static let account = "volcengine-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String?) {
        SecItemDelete(query as CFDictionary)
        guard let key, let data = key.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// What can go wrong, as the toast says it.
enum VoiceError: LocalizedError {
    case microphoneDenied
    case noMicrophone
    case rejected
    case network(String)
    case busy
    /// The key has no quota for the chosen model: not enabled, or used up.
    case noQuota
    case server(code: Int, message: String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: String(localized: "没有麦克风权限，请在系统设置里打开")
        case .noMicrophone: String(localized: "没有可用的麦克风")
        case .rejected: String(localized: "火山引擎没有接受这个 API Key，请检查 Key 和开通的计费方式")
        case .network(let detail): String(localized: "连不上火山引擎：\(detail)")
        case .busy: String(localized: "识别服务繁忙，请稍后再试")
        case .noQuota: String(localized: "所选计费方式没有可用额度：可能没有开通，或额度已用完。请到控制台确认，或换成你开通的计费方式")
        // The code as digits, without the locale's grouping.
        case .server(let code, let message): String(localized: "语音识别出错（\(String(code))）：\(message)")
        case .timedOut: String(localized: "识别超时，请再说一次")
        }
    }
}

/// Recognition with Volcengine for one hold: the microphone runs from the moment the finger
/// lands, its audio queues while the connection opens, and the text arrives as it is heard.
@MainActor
final class VolcTranscriber: SpeechTranscriber {
    private let stream: VolcStream
    private let mic = MicCapture()
    private var reader: Task<Void, Never>?

    init(key: String, resource: VolcSpeech.Resource) {
        stream = VolcStream(key: key, resource: resource.rawValue)
    }

    func start(
        partial: @escaping @MainActor (String) -> Void,
        level: @escaping @MainActor (Float) -> Void,
        failed: @escaping @MainActor (Error) -> Void
    ) async throws {
        guard AVAudioApplication.shared.recordPermission == .granted else { throw VoiceError.microphoneDenied }
        let stream = stream
        mic.onChunk = { stream.send(audio: $0, last: false) }
        mic.onLevel = { value in Task { @MainActor in level(value) } }
        stream.onText = { text in Task { @MainActor in partial(text) } }
        try await mic.start()
        reader = Task {
            do {
                try await stream.open()
            } catch {
                guard !Task.isCancelled else { return }
                failed(error)
            }
        }
    }

    func finish() async throws -> String {
        let rest = await mic.stop()
        stream.send(audio: rest, last: true)
        defer {
            reader?.cancel()
            stream.close()
        }
        return try await stream.result(timeout: .seconds(10))
    }

    func cancel() {
        reader?.cancel()
        stream.close()
        Task { _ = await mic.stop() }
    }
}

/// One recognition session on the WebSocket: Volcengine's binary frames, sent in order from any
/// thread, and the running text out.
final class VolcStream: @unchecked Sendable {
    private let lock = NSLock()
    private let socket: URLSessionWebSocketTask
    private let session: URLSession
    private let outbox: AsyncStream<(Data, Bool)>.Continuation
    private let packets: AsyncStream<(Data, Bool)>
    private var text = ""
    private var outcome: Result<String, Error>?
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var tasks: [Task<Void, Never>] = []
    /// The whole running transcript, each time it changes. Called off the main thread.
    var onText: (@Sendable (String) -> Void)?

    init(key: String, resource: String) {
        var request = URLRequest(url: VolcSpeech.endpoint)
        let id = UUID().uuidString
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.timeoutInterval = 15
        session = URLSession(configuration: .ephemeral)
        socket = session.webSocketTask(with: request)
        (packets, outbox) = AsyncStream.makeStream()
    }

    /// Queue audio (16 kHz mono 16-bit PCM). The last packet ends the utterance.
    func send(audio: Data, last: Bool) {
        outbox.yield((audio, last))
        if last { outbox.finish() }
    }

    /// Connect and run until the final text or a failure; audio sent before this queues.
    /// Throws when the session fails before the final text.
    func open() async throws {
        socket.resume()
        let socket = socket
        let packets = packets
        let sender = Task {
            do {
                var sequence: Int32 = 1
                try await socket.send(.data(VolcFrame.request(sequence: sequence, json: Self.parameters)))
                for await (audio, last) in packets {
                    sequence += 1
                    try await socket.send(.data(VolcFrame.audio(sequence: sequence, pcm: audio, last: last)))
                    if last { break }
                }
            } catch {
                self.settle(.failure(self.translate(error)))
            }
        }
        lock.withLock { tasks.append(sender) }
        do {
            while true {
                let message = try await socket.receive()
                guard case .data(let data) = message, let frame = VolcFrame.parse(data) else { continue }
                if let code = frame.errorCode {
                    // Nothing heard at all: an empty result, not an error.
                    if code == 45_000_002 { settle(.success("")); return }
                    switch code {
                    case 55_000_031: throw VoiceError.busy
                    case 45_000_292: throw VoiceError.noQuota
                    default: throw VoiceError.server(code: code, message: frame.message ?? "")
                    }
                }
                if let heard = frame.text {
                    let changed = lock.withLock { () -> Bool in
                        guard heard != text else { return false }
                        text = heard
                        return true
                    }
                    if changed { onText?(heard) }
                }
                if frame.last {
                    settle(.success(lock.withLock { text }))
                    return
                }
            }
        } catch {
            let failure = translate(error)
            settle(.failure(failure))
            throw failure
        }
    }

    /// The final text once the last packet is answered. On a timeout, what was heard so far.
    func result(timeout: Duration) async throws -> String {
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            let heard = lock.withLock { text }
            settle(heard.isEmpty ? .failure(VoiceError.timedOut) : .success(heard))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { waiter in
            let ready = lock.withLock { () -> Result<String, Error>? in
                if let outcome { return outcome }
                waiters.append(waiter)
                return nil
            }
            if let ready { waiter.resume(with: ready) }
        }
    }

    func close() {
        outbox.finish()
        let running = lock.withLock { tasks }
        running.forEach { $0.cancel() }
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        settle(.failure(CancellationError()))
    }

    /// The first outcome wins; later ones (a close after the final text) are dropped.
    private func settle(_ result: Result<String, Error>) {
        let waiting = lock.withLock { () -> [CheckedContinuation<String, Error>] in
            guard outcome == nil else { return [] }
            outcome = result
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume(with: result) }
    }

    private func translate(_ error: Error) -> Error {
        if error is VoiceError || error is CancellationError { return error }
        if let response = socket.response as? HTTPURLResponse, [401, 403].contains(response.statusCode) {
            return VoiceError.rejected
        }
        return VoiceError.network(error.localizedDescription)
    }

    /// Dictation: punctuation, numbers written as numbers, filler words dropped, and the second
    /// pass that re-recognizes each finished sentence more accurately.
    private static let parameters: Data = {
        let json: [String: Any] = [
            "audio": ["format": "pcm", "codec": "raw", "rate": 16_000, "bits": 16, "channel": 1],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": true,
                "enable_nonstream": true,
                "result_type": "full",
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }()
}

/// Volcengine's frame: a 4-byte header (version, header size, message type and flags,
/// serialization and compression), a big-endian sequence and size, then the gzipped payload.
enum VolcFrame {
    struct Parsed {
        var last = false
        var errorCode: Int?
        var message: String?
        var text: String?
    }

    static func request(sequence: Int32, json: Data) -> Data {
        frame(type: 0b0001, flags: 0b0001, serialization: 0b0001, sequence: sequence, payload: Gzip.compress(json))
    }

    static func audio(sequence: Int32, pcm: Data, last: Bool) -> Data {
        frame(type: 0b0010, flags: last ? 0b0011 : 0b0001, serialization: 0, sequence: last ? -sequence : sequence, payload: Gzip.compress(pcm))
    }

    private static func frame(type: UInt8, flags: UInt8, serialization: UInt8, sequence: Int32, payload: Data) -> Data {
        var data = Data([0x11, type << 4 | flags, serialization << 4 | 0b0001, 0])
        data.append(bigEndian: UInt32(bitPattern: sequence))
        data.append(bigEndian: UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func parse(_ data: Data) -> Parsed? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let headerSize = Int(bytes[0] & 0x0f) * 4
        let type = bytes[1] >> 4
        let flags = bytes[1] & 0x0f
        let serialization = bytes[2] >> 4
        let compression = bytes[2] & 0x0f
        var index = headerSize
        func word() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            defer { index += 4 }
            return bytes[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        var parsed = Parsed()
        if flags & 0b0001 != 0 { _ = word() }
        if flags & 0b0010 != 0 { parsed.last = true }
        if flags & 0b0100 != 0 { _ = word() }
        switch type {
        case 0b1001:
            break
        case 0b1111:
            guard let code = word() else { return nil }
            parsed.errorCode = Int(code)
        default:
            return nil
        }
        guard let size = word() else { return parsed }
        var payload = Data(bytes[index..<min(bytes.count, index + Int(size))])
        if compression == 0b0001, let inflated = Gzip.decompress(payload) { payload = inflated }
        if serialization == 0b0001, let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            parsed.text = Self.text(in: json["result"])
            if parsed.errorCode != nil { parsed.message = json["error"] as? String ?? json["message"] as? String }
        }
        if parsed.errorCode != nil, parsed.message == nil { parsed.message = String(data: payload, encoding: .utf8) }
        return parsed
    }

    /// `result.text`; the result is an object, or a list of them in some replies.
    private static func text(in result: Any?) -> String? {
        if let result = result as? [String: Any] { return result["text"] as? String }
        if let results = result as? [[String: Any]] { return results.compactMap { $0["text"] as? String }.joined() }
        return nil
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

/// gzip around the system's raw DEFLATE.
enum Gzip {
    static func compress(_ data: Data) -> Data {
        let deflated = (try? (data as NSData).compressed(using: .zlib)) as Data? ?? Data()
        var out = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(deflated)
        Swift.withUnsafeBytes(of: crc32(data).littleEndian) { out.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 { index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8) }
        if flags & 0x08 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x10 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x02 != 0 { index += 2 }
        guard index <= bytes.count - 8 else { return nil }
        let body = Data(bytes[index..<bytes.count - 8])
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }

    private static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xff)] ^ ($0 >> 8) }
    }
}

/// The microphone as 16 kHz mono 16-bit PCM in 200 ms packets, plus the input level. The
/// audio session and engine start and stop on their own queue, so the hold's first frame
/// is never waiting on them.
final class MicCapture: @unchecked Sendable {
    static let chunkBytes = 6_400

    var onChunk: (@Sendable (Data) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "voice.microphone")
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var lastLevel: TimeInterval = 0
    private var running = false

    func start() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.begin()
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// Stop and hand back what has not made a full packet yet.
    func stop() async -> Data {
        await withCheckedContinuation { (done: CheckedContinuation<Data, Never>) in
            queue.async {
                self.end()
                let rest = self.lock.withLock { () -> Data in
                    defer { self.pending = Data() }
                    return self.pending
                }
                done.resume(returning: rest)
            }
        }
    }

    private func begin() throws {
        let session = AVAudioSession.sharedInstance()
        // Other audio ducks while recording; haptics keep working (the cancel tick).
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw VoiceError.noMicrophone
        }
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        running = true
    }

    private func end() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        reportLevel(buffer)
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
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
        guard out.frameLength > 0, let samples = out.int16ChannelData else { return }
        let data = Data(bytes: samples[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
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

    /// RMS in dB, -50…-10 mapped to 0…1, about twenty times a second.
    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevel >= 0.05, let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        lastLevel = now
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-7))
        onLevel?(min(max((decibels + 50) / 40, 0), 1))
    }
}
