import ActivityKit
import Observation
import SwiftUI
import UIKit

/// What a conversation tells its voice call (`SessionModel.callListener`).
enum CallSignal {
    case turnStarted
    /// A piece of the answer's text, as the model writes it.
    case text(String)
    case turnEnded(failed: Bool)
}

/// The voices a call can speak in: Volcengine's 豆包语音合成模型 2.0 voices that suit a
/// conversation. The name is Volcengine's own and stays as it is in every language.
struct CallVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let female: Bool
    let english: Bool

    var kind: String {
        if english { return female ? String(localized: "英语女声") : String(localized: "英语男声") }
        return female ? String(localized: "女声") : String(localized: "男声")
    }

    static let all: [CallVoice] = [
        CallVoice(id: "zh_female_vv_uranus_bigtts", name: "Vivi", female: true, english: false),
        CallVoice(id: "zh_female_xiaohe_uranus_bigtts", name: "小何", female: true, english: false),
        CallVoice(id: "zh_male_m191_uranus_bigtts", name: "云舟", female: false, english: false),
        CallVoice(id: "zh_male_taocheng_uranus_bigtts", name: "小天", female: false, english: false),
        CallVoice(id: "zh_female_qingxinnvsheng_uranus_bigtts", name: "清新女声", female: true, english: false),
        CallVoice(id: "zh_female_zhixingnv_uranus_bigtts", name: "知性女声", female: true, english: false),
        CallVoice(id: "zh_female_shuangkuaisisi_uranus_bigtts", name: "爽快思思", female: true, english: false),
        CallVoice(id: "zh_female_linjianvhai_uranus_bigtts", name: "邻家女孩", female: true, english: false),
        CallVoice(id: "zh_male_liufei_uranus_bigtts", name: "刘飞", female: false, english: false),
        CallVoice(id: "zh_male_ruyaqingnian_uranus_bigtts", name: "儒雅青年", female: false, english: false),
        CallVoice(id: "zh_male_kailangxuezhang_uranus_bigtts", name: "开朗学长", female: false, english: false),
        CallVoice(id: "zh_male_shenyeboke_uranus_bigtts", name: "深夜播客", female: false, english: false),
        CallVoice(id: "en_female_dacey_uranus_bigtts", name: "Dacey", female: true, english: true),
        CallVoice(id: "en_male_tim_uranus_bigtts", name: "Tim", female: false, english: true),
    ]

    private static let key = "callVoice"

    static var chosen: CallVoice {
        get { all.first { $0.id == UserDefaults.standard.string(forKey: key) } ?? all[0] }
        set { UserDefaults.standard.set(newValue.id, forKey: key) }
    }
}

/// The call on screen or minimized, at most one at a time, and where it shows.
@MainActor
@Observable
final class CallCenter {
    static let shared = CallCenter()

    private(set) var call: VoiceCall?
    /// Full screen; otherwise the bubble over the app.
    private(set) var expanded = false

    @ObservationIgnored private lazy var window = CallWindow()
    @ObservationIgnored private lazy var bubble = CallBubbleWindow()

    private init() {}

    var active: Bool { call.map { !$0.ended } ?? false }

    func checkActive(callId: String) throws {
        guard active, call?.callId == callId else { throw CancellationError() }
    }

    /// Call `sessionId`. Another call ends first; calling the same conversation again opens it.
    func start(sessionId: String, botId: String?, title: String, app: AppModel) {
        if let call, call.sessionId == sessionId, !call.ended {
            expand()
            return
        }
        call?.hangUp()
        let call = VoiceCall(sessionId: sessionId, botId: botId, title: title, app: app)
        self.call = call
        Haptics.firm()
        expand()
        Task { await call.start() }
    }

    func expand() {
        guard let call, !call.ended else { return }
        expanded = true
        bubble.hide()
        window.show(call)
    }

    func minimize() {
        guard let call else { return }
        expanded = false
        window.hide()
        bubble.show(call)
    }

    /// A call that failed shows why, wherever it was.
    func reveal(_ call: VoiceCall) {
        guard self.call === call else { return }
        expanded = true
        bubble.hide()
        window.show(call)
    }

    /// The call is over: the screen says so for a moment (longer when it says why), then goes.
    func finished(_ call: VoiceCall) {
        guard self.call === call else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(expanded ? (call.endReason == nil ? 1_200 : 3_000) : 0))
            guard self.call === call else { return }
            self.call = nil
            expanded = false
            window.hide(release: true)
            bubble.hide(release: true)
        }
    }
}

/// The levels the call's face moves with, kept apart from the call so twenty updates a second
/// redraw only the face.
@MainActor
@Observable
final class CallLevels {
    /// The microphone (the user) and the reply being heard (her), 0…1.
    var input: Float = 0
    var output: Float = 0

    @ObservationIgnored private var sampler: Task<Void, Never>?

    func startSampling() {
        sampler?.cancel()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stopSampling() {
        sampler?.cancel()
        sampler = nil
        input = 0
        output = 0
    }

    /// When her sound last started, and when the last of it was heard.
    @ObservationIgnored var soundStarted: Date?
    @ObservationIgnored var lastSound: Date?
    /// Her sound and the microphone while it plays, for the diagnostics: with the echo canceller
    /// working the microphone stays near the room's own quiet.
    @ObservationIgnored private var stretch: (count: Int, output: Float, input: Float, peak: Float) = (0, 0, 0, 0)
    /// The microphone through her sound, a reading every 50 ms, for the diagnostics.
    @ObservationIgnored private var stretchTrace: [Float] = []

    private func sample() {
        let now = Date()
        // While her reply is heard the microphone hears mostly her echo.
        if output > 0.04 {
            if stretch.count == 0 { soundStarted = now }
            stretch = (stretch.count + 1, stretch.output + output, stretch.input + input, max(stretch.peak, input))
            stretchTrace.append(input)
        } else if stretch.count > 0 {
            let n = Float(stretch.count)
            let readings = stretchTrace.map { String(Int(($0 * 100).rounded())) }.joined(separator: " ")
            CallDiagnostics.note(String(format: "her sound %d ms: level %.2f, microphone %.2f (peak %.2f); microphone every 50 ms: ",
                                        stretch.count * 50, stretch.output / n, stretch.input / n, stretch.peak) + readings)
            stretch = (0, 0, 0, 0)
            stretchTrace = []
        }
    }
}

/// One voice call with a conversation (DSH's own or a Bot's chat): the microphone goes to
/// Volcengine's streaming recognition; each sentence it hears to its end is sent as a message;
/// the answer is spoken by Volcengine's streaming synthesis as the model writes it. Talking over
/// the answer stops it and the turn behind it, and what was said is the next message. Every
/// judgement of when a sentence ends is Volcengine's.
@MainActor
@Observable
final class VoiceCall {
    enum Phase: Equatable {
        case connecting, listening, thinking, speaking
    }

    /// Something the screen says besides the conversation.
    enum Notice: Equatable {
        case reconnecting
        /// The system took the audio (a phone call, Siri, an alarm); the call goes on after.
        case paused
        case problem(String)
    }

    let sessionId: String
    let botId: String?
    let title: String
    let levels = CallLevels()
    fileprivate let callId = UUID().uuidString.lowercased()

    private(set) var phase = Phase.connecting {
        didSet {
            guard phase != oldValue else { return }
            updateActivity()
        }
    }
    private(set) var muted = false {
        didSet { if muted != oldValue { updateActivity() } }
    }
    private(set) var speaker = true
    /// Headphones or a Bluetooth headset carry the sound: the speaker switch has no say.
    private(set) var externalRoute = false
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var notice: Notice?
    /// Why the call could not start or had to stop; the screen offers the settings.
    private(set) var failure: String?
    private(set) var ended = false
    /// Why the call ended by itself, for the screen that says it ended.
    private(set) var endReason: String?
    /// Nobody has talked for a while: the call ends at this moment unless the user speaks or
    /// says to go on.
    private(set) var idleDeadline: Date?

    @ObservationIgnored let app: AppModel
    @ObservationIgnored private var session: SessionModel?
    @ObservationIgnored private var audio: CallAudio?
    @ObservationIgnored private var recognizer: CallRecognizer?
    @ObservationIgnored private var synthesizer: CallSynthesizer?
    @ObservationIgnored private var renewal: Task<Void, Never>?
    @ObservationIgnored private var leaseId: String?
    // Send state changes in order across calls, including a hang-up followed by an immediate redial.
    private static var lastStateReport: Task<Void, Never>?
    @ObservationIgnored private var reconnectNotice: Task<Void, Never>?
    @ObservationIgnored private var noticeExpiry: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var idleWatch: Task<Void, Never>?
    /// The last time the user was heard, or did something, or she was busy.
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var idleTimerWas = false
    /// The system has the audio (a phone call, Siri, an alarm): nothing is heard or played.
    @ObservationIgnored private var pausedBySystem = false
    /// What the user is saying, or said last (for the diagnostics).
    @ObservationIgnored private var heard = ""

    /// A message went out; its turn has not started yet.
    @ObservationIgnored private var armed = false
    /// The last spoken sentence still going into the engine.
    @ObservationIgnored private var lastSubmission: Task<Void, Never>?
    /// The turn answering the last message is running: its text is spoken.
    @ObservationIgnored private var inTurn = false
    /// The reply being spoken (`CallSynthesizer`), and whether all of it has been made.
    @ObservationIgnored private var reply: Int?
    @ObservationIgnored private var replyMade = false
    /// Sentences of the reply in the order they are made, with their sound still to be heard.
    @ObservationIgnored private var sentence = 0
    @ObservationIgnored private var unheard: [Int: Int] = [:]
    /// The conversation so far, for recognition's context.
    @ObservationIgnored private var lastUserText = ""
    @ObservationIgnored private var replyText = ""
    @ObservationIgnored private var idleQuestion: String?
    @ObservationIgnored private var idleReminder: (requestId: String, report: Task<Void, Never>)?
    @ObservationIgnored private var speakable = SpeakableStream()

    init(sessionId: String, botId: String?, title: String, app: AppModel) {
        self.sessionId = sessionId
        self.botId = botId
        self.title = title
        self.app = app
    }

    var bot: BotInfo? { botId.flatMap { app.botTeam.bot($0) } }

    /// Something waits on the user in the conversation: a tool to approve, a question.
    var waitingOnUser: Bool { app.isWaiting(sessionId) }

    // MARK: Start and end

    func start() async {
        guard !ended else { return }
        guard let credential = VolcSpeech.shared.credential else {
            fail(CallError.noKey.localizedDescription)
            return
        }
        ReadAloud.shared.stop()
        BackgroundKeeper.shared.setCallActive(true)
        idleTimerWas = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true

        let session = app.localSessions.acquire(sessionId) { [app, sessionId] in
            let model = SessionModel(sessionId: sessionId, app: app)
            model.subagentAddress = app.subagentAddress(for: sessionId)
            return model
        }
        self.session = session
        session.callListener = { [weak self] signal in self?.conversation(signal) }
        lastUserText = session.items.lastUserText ?? ""
        replyText = session.items.lastAssistantText ?? ""
        renew()

        let recognizer = CallRecognizer(credential: credential)
        recognizer.setContext(context())
        recognizer.onEvent = { [weak self] event in Task { @MainActor in self?.recognized(event) } }
        self.recognizer = recognizer

        let synthesizer = CallSynthesizer(credential: credential, voice: VoiceChoices.shared.callVoice(sessionId: sessionId, botId: botId).id)
        synthesizer.onEvent = { [weak self] event in Task { @MainActor in self?.synthesized(event) } }
        synthesizer.warmUp()
        self.synthesizer = synthesizer

        let audio = CallAudio()
        audio.onChunk = { [weak recognizer] chunk in recognizer?.send(chunk) }
        audio.onInputLevel = { [weak self] value in Task { @MainActor in self?.levels.input = value } }
        audio.onOutputLevel = { [weak self] value in Task { @MainActor in self?.levels.output = value } }
        audio.onPlayed = { [weak self] tag in Task { @MainActor in self?.played(tag) } }
        audio.onReminderStarted = { [weak self] id in
            Task { @MainActor in
                guard let self, !self.ended, self.reply == id else { return }
                self.recordIdleQuestion()
            }
        }
        audio.onRoute = { [weak self] speaker, external in
            Task { @MainActor in
                self?.speaker = speaker
                self?.externalRoute = external
            }
        }
        audio.onHalt = { [weak self] halt in
            Task { @MainActor in
                switch halt {
                case .interrupted:
                    self?.app.showToast(String(localized: "通话被系统打断，已挂断"))
                    self?.hangUp()
                case .failed(let message):
                    self?.fail(message)
                }
            }
        }
        audio.onPause = { [weak self] paused in Task { @MainActor in self?.setPaused(paused) } }
        self.audio = audio
        do {
            try await audio.start()
        } catch {
            fail(CallError.microphone(error.localizedDescription).localizedDescription)
            return
        }
        guard !ended else { return }
        recognizer.start()
        levels.startSampling()
        startedAt = Date()
        phase = .listening
        startActivity()
        watchIdle()
    }

    func hangUp() {
        guard !ended else { return }
        ended = true
        endedAt = Date()
        Haptics.tap()
        teardown()
        CallCenter.shared.finished(self)
    }

    private func fail(_ message: String) {
        guard !ended else { return }
        log("failed: \(message)")
        failure = message
        Haptics.error()
        teardown()
        ended = true
        endedAt = Date()
        // The screen comes up (from the bar, too) with the reason, until it is closed.
        CallCenter.shared.reveal(self)
    }

    /// Close a call that failed.
    func dismiss() {
        CallCenter.shared.finished(self)
    }

    private func teardown() {
        levels.stopSampling()
        recognizer?.stop()
        recognizer = nil
        synthesizer?.close()
        synthesizer = nil
        audio?.stop()
        audio = nil
        renewal?.cancel()
        reconnectNotice?.cancel()
        noticeExpiry?.cancel()
        watchdog?.cancel()
        idleWatch?.cancel()
        idleDeadline = nil
        idleQuestion = nil
        idleReminder?.report.cancel()
        idleReminder = nil
        if let session {
            session.callListener = nil
            app.localSessions.release(session.sessionId)
            self.session = nil
            report(active: false)
        }
        levels.input = 0
        levels.output = 0
        UIApplication.shared.isIdleTimerDisabled = idleTimerWas
        BackgroundKeeper.shared.setCallActive(false)
        endActivity()
    }

    // MARK: Live Activity

    @ObservationIgnored private var activity: Activity<CallActivityAttributes>?
    @ObservationIgnored private var shownState: CallActivityAttributes.ContentState?

    /// The call on the lock screen and in the Dynamic Island, with 静音 and 结束 that reach it here.
    private func startActivity() {
        CallActivityBridge.onToggleMute = { [weak self] in self?.toggleMute() }
        CallActivityBridge.onHangUp = { [weak self] in self?.hangUp() }
        observeWaiting()
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let state = activityState else { return }
        // One left from a call the app did not get to end (it was closed mid-call).
        for stale in Activity<CallActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        do {
            let attributes = CallActivityAttributes(title: title, avatar: drawAvatar())
            activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
            shownState = state
        } catch {
            log("live activity not started: \(error.localizedDescription)")
        }
    }

    /// The face for the Live Activity, drawn the way the app draws it, into the App Group; earlier
    /// calls' faces go. A new name each call, so the system never shows a cached old one.
    private func drawAvatar() -> String? {
        guard let folder = CallAvatarFile.folder else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            try? FileManager.default.removeItem(at: folder.appending(path: old))
        }
        let size: CGFloat = 44
        let face: AnyView
        if let bot {
            face = AnyView(BotAvatar(bot: bot, size: size).environment(app))
        } else {
            face = AnyView(Image("LaunchMark").resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle()))
        }
        let renderer = ImageRenderer(content: face.frame(width: size, height: size))
        renderer.scale = 3
        let name = "face-\(UUID().uuidString.prefix(8)).png"
        guard let data = renderer.uiImage?.pngData(), let url = CallAvatarFile.url(name),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return name
    }

    private var activityState: CallActivityAttributes.ContentState? {
        guard let startedAt else { return nil }
        let shown: CallActivityAttributes.ContentState.Phase = if waitingOnUser { .waiting } else {
            switch phase {
            case .connecting: .connecting
            case .listening: .listening
            case .thinking: .thinking
            case .speaking: .speaking
            }
        }
        return CallActivityAttributes.ContentState(phase: shown, muted: muted, startedAt: startedAt)
    }

    private func updateActivity() {
        guard let activity, let state = activityState, state != shownState else { return }
        shownState = state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endActivity() {
        CallActivityBridge.onToggleMute = nil
        CallActivityBridge.onHangUp = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Something to approve or answer comes and goes in the conversation, not in the call.
    private func observeWaiting() {
        guard !ended else { return }
        withObservationTracking { _ = waitingOnUser } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateActivity()
                self?.observeWaiting()
            }
        }
    }

    // MARK: Controls

    func toggleMute() {
        muted.toggle()
        audio?.setMuted(muted)
        Haptics.select()
        stillHere()
    }

    func toggleSpeaker() {
        guard !externalRoute else { return }
        speaker.toggle()
        audio?.setSpeaker(speaker)
        Haptics.select()
        stillHere()
    }

    /// 继续通话: the user is there after all.
    func keepTalking() {
        Haptics.select()
        // Her question stops if it is still being asked.
        if phase == .speaking, !inTurn, !armed {
            stopSpeaking()
            phase = .listening
        }
        stillHere()
    }

    // MARK: Nobody talking

    /// Volcengine bills recognition by the sound sent to it, so a call left open bills all night
    /// whether anyone talks or not. After this long with nothing heard from the user while she is
    /// neither working on an answer nor speaking, she asks whether anyone is there.
    private static var idleLimit: TimeInterval {
        #if DEBUG
        // `-dshCallIdle 10`: ask after ten seconds, to try it.
        let seconds = UserDefaults.standard.double(forKey: "dshCallIdle")
        if seconds > 0 { return seconds }
        #endif
        return 180
    }
    /// And after this much more of nothing, the call ends.
    static let idleGrace: TimeInterval = 30

    private func watchIdle() {
        lastActivity = Date()
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.checkIdle()
            }
        }
    }

    private func checkIdle() {
        guard !ended else { return }
        let now = Date()
        if let idleDeadline {
            guard now >= idleDeadline else { return }
            log("nobody talked: hanging up")
            let reason = String(localized: "很久没听到你说话，已自动挂断")
            endReason = reason
            app.showToast(reason)
            hangUp()
            return
        }
        // Only her silence counts: working on an answer or saying it is the call going on. Not
        // while the system has paused the call, though: then she is not heard either.
        guard phase == .listening || pausedBySystem else {
            lastActivity = now
            return
        }
        guard now.timeIntervalSince(lastActivity) >= Self.idleLimit else { return }
        log("nobody talked for \(Int(Self.idleLimit)) s: asking")
        idleDeadline = now.addingTimeInterval(Self.idleGrace)
        Haptics.warning()
        // Synthesized locally, outside a conversation turn.
        if let synthesizer, reply == nil, !inTurn, !armed {
            let id = synthesizer.begin()
            reply = id
            replyMade = false
            sentence = 0
            unheard = [:]
            let question = String(localized: "还在吗？没声音的话我先挂了")
            idleQuestion = question
            synthesizer.say(question, reply: id)
            synthesizer.end(reply: id)
        }
    }

    /// The user spoke or touched the call: the quiet starts again from now.
    private func stillHere() {
        lastActivity = Date()
        guard idleDeadline != nil else { return }
        log("someone is there: the call goes on")
        idleDeadline = nil
    }

    // MARK: The engine

    /// Tell the engine this conversation is on a call, now and every 30 s: its plugin
    /// (`engine/plugins/ios-call`) gives each turn a note to answer briefly, aloud.
    private func renew() {
        report(active: true)
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                self.report(active: true)
            }
        }
    }

    private func report(active: Bool) {
        let previous = Self.lastStateReport
        let client = app.client
        let body: JSON = ["sessionId": .string(sessionId), "callId": .string(callId), "active": .bool(active)]
        Self.lastStateReport = Task { [weak self] in
            await previous?.value
            let response = await Self.post("state", body, client: client)
            if active, let id = response?["leaseId"].string { self?.leaseId = id }
        }
    }

    private static func post(_ path: String, _ body: JSON, client: EngineClient) async -> JSON? {
        var request = client.request(client.origin.appendingPathComponent("api/ios-call/\(path)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONEncoder().encode(body)
        request.timeoutInterval = 10
        guard let (data, response) = try? await client.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSON.parse(data)
    }

    private func recordIdleQuestion() {
        guard let question = idleQuestion else { return }
        idleQuestion = nil
        replyText = question
        recognizer?.setContext(context())
        guard let leaseId else { return }
        let requestId = UUID().uuidString.lowercased()
        let client = app.client
        let body: JSON = ["sessionId": .string(sessionId), "leaseId": .string(leaseId),
                          "requestId": .string(requestId), "text": .string(question)]
        idleReminder = (requestId, Task { _ = await Self.post("said", body, client: client) })
    }

    private func recordIdleQuestionIfHeard() {
        guard idleQuestion != nil, let reply, audio?.hasStartedReminder(reply) == true else { return }
        recordIdleQuestion()
    }

    // MARK: Hearing the user

    private func recognized(_ event: CallRecognizer.Event) {
        guard !ended else { return }
        switch event {
        case .partial(let text):
            guard !text.isEmpty else { return }
            // Where in the call speech was first heard: during her sound it may be her echo.
            if heard.isEmpty || !text.hasPrefix(String(heard.prefix(1))) { log("heard start \(soundContext): \(text)") }
            heard = text
            stillHere()
            interrupt()
        case .sentence(let text):
            log("heard sentence \(soundContext): \(text)")
            heard = text
            stillHere()
            interrupt()
            deliver(text)
        case .unstable:
            reconnectNotice?.cancel()
            // Nothing is sent while the call is paused, and Volcengine may close the idle
            // connection: that is not the network.
            guard !pausedBySystem else { return }
            // A blip is not worth a word; a connection still down after two seconds is.
            reconnectNotice = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.notice = .reconnecting
            }
        case .steady:
            reconnectNotice?.cancel()
            if notice == .reconnecting { notice = nil }
        case .failed(let error):
            fail(error.localizedDescription)
        }
    }

    /// The user talks over the answer, or while it is being worked on: it stops, and so does the
    /// turn. What they said comes next.
    private func interrupt() {
        guard phase == .speaking || phase == .thinking else { return }
        log("interrupted while \(phase)")
        stopSpeaking()
        if inTurn || armed, let session, session.running {
            Task { await session.cancel() }
        }
        inTurn = false
        armed = false
        watchdog?.cancel()
        phase = .listening
    }

    /// The system took the audio for a while, or gave it back. Nobody can talk in between,
    /// so the quiet before she asks whether anyone is there keeps counting: a call left
    /// paused (a long phone call) still ends, as a quiet one would.
    private func setPaused(_ value: Bool) {
        guard !ended else { return }
        log(value ? "paused by the system" : "resumed after the system")
        pausedBySystem = value
        noticeExpiry?.cancel()
        reconnectNotice?.cancel()
        if value {
            notice = .paused
        } else {
            // The quiet counts again from the moment the call can hear.
            lastActivity = Date()
            if notice == .paused { notice = nil }
        }
    }

    private func stopSpeaking() {
        if let reply { synthesizer?.cancel(reply: reply) }
        if audio?.flush(reminder: idleQuestion == nil ? nil : reply) == true { recordIdleQuestion() }
        reply = nil
        idleQuestion = nil
        unheard = [:]
        levels.output = 0
    }

    private func deliver(_ text: String) {
        guard let session else { return }
        lastUserText = text
        replyText = ""
        armed = true
        phase = .thinking
        // Show each sentence right away. Wait for the previous one to enter the engine before
        // submitting the next, even if the previous one is waiting for the reminder report.
        let reminder = idleReminder
        idleReminder = nil
        lastSubmission = session.composer.send(prompt: text, voiceCallId: callId,
                                              idleReminder: reminder, after: lastSubmission)
        recognizer?.setContext(context())
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.armed else { return }
            self.armed = false
            self.phase = .listening
            self.show(.problem(String(localized: "没有收到回答，请再说一次")))
        }
    }

    // MARK: The conversation answering

    private func conversation(_ signal: CallSignal) {
        guard !ended else { return }
        switch signal {
        case .turnStarted:
            guard armed else { return }
            log("turn started")
            armed = false
            inTurn = true
            speakable = SpeakableStream()
            watchdog?.cancel()
        case .text(let text):
            guard inTurn, let synthesizer else { return }
            // Code is for reading, not for hearing: a fenced block stays in the conversation only.
            let spoken = speakable.take(text)
            guard !spoken.isEmpty else { return }
            if reply == nil {
                reply = synthesizer.begin()
                replyMade = false
                sentence = 0
                unheard = [:]
            }
            replyText += spoken
            synthesizer.say(spoken, reply: reply!)
        case .turnEnded(let failed):
            guard inTurn else { return }
            log("turn ended, failed: \(failed), spoken: \(reply != nil)")
            inTurn = false
            if let reply {
                synthesizer?.end(reply: reply)
            } else {
                phase = .listening
                if failed { show(.problem(String(localized: "这一轮出错了，详情在对话里"))) }
            }
            recognizer?.setContext(context())
        }
    }

    // MARK: Speaking

    private func synthesized(_ event: CallSynthesizer.Event) {
        guard !ended else { return }
        switch event {
        case .sentenceStart(let id):
            guard id == reply else { return }
            sentence += 1
        case .audio(let id, let pcm):
            guard id == reply, let audio else { return }
            let tag = sentence
            unheard[tag, default: 0] += 1
            audio.play(pcm, tag: tag, reminder: idleQuestion == nil ? nil : id)
            if phase != .speaking {
                log("speaking")
                phase = .speaking
            }
        case .sentenceEnd:
            break
        case .finished(let id):
            guard id == reply else { return }
            replyMade = true
            if unheard.values.allSatisfy({ $0 == 0 }) { doneSpeaking() }
        case .failed(let id, let error):
            log("synthesis failed (\(String(describing: id))): \(error.localizedDescription)")
            if error as? CallError == .synthesisRefused {
                fail(error.localizedDescription)
                return
            }
            show(.problem(String(localized: "语音合成出错：\(error.localizedDescription)")))
            if id == nil || id == reply {
                recordIdleQuestionIfHeard()
                reply = nil
                idleQuestion = nil
                if unheard.values.allSatisfy({ $0 == 0 }) && !inTurn { phase = .listening }
            }
        }
    }

    private func played(_ tag: Int) {
        levels.lastSound = Date()
        guard reply != nil, let count = unheard[tag] else { return }
        // Completion may reach the main actor before the reminder's start notification.
        recordIdleQuestionIfHeard()
        unheard[tag] = max(count - 1, 0)
        if replyMade, unheard.values.allSatisfy({ $0 == 0 }) { doneSpeaking() }
    }

    private func doneSpeaking() {
        log("done speaking")
        reply = nil
        idleQuestion = nil
        levels.output = 0
        if !inTurn && !armed { phase = .listening }
    }

    // MARK: Helpers

    /// For the diagnostics: whether her sound was playing when the user was heard, and how long since
    /// it started or stopped. Speech heard while she plays, soon after her sound starts, is her echo
    /// leaking past the echo canceller.
    private var soundContext: String {
        let now = Date()
        if phase == .speaking, let since = levels.soundStarted {
            return "while she speaks, \(Int(now.timeIntervalSince(since) * 1000)) ms in"
        }
        if let last = levels.lastSound { return "\(Int(now.timeIntervalSince(last) * 1000)) ms after her sound" }
        return "before she spoke"
    }

    private func log(_ message: @autoclosure () -> String) {
        CallDiagnostics.note(message())
    }

    private func show(_ value: Notice) {
        notice = value
        noticeExpiry?.cancel()
        noticeExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.notice == value else { return }
            self?.notice = nil
        }
    }

    /// The last exchange, short: what recognition is told of the conversation.
    private func context() -> [(user: Bool, text: String)] {
        var turns: [(user: Bool, text: String)] = []
        if !lastUserText.isEmpty { turns.append((true, String(lastUserText.suffix(60)))) }
        if !replyText.isEmpty { turns.append((false, String(replyText.suffix(120)))) }
        return turns
    }
}

/// The answer's text as it streams, without its fenced code blocks: what is said aloud. A fence's
/// backticks can arrive split across pieces, so a run of them waits for the next piece.
struct SpeakableStream {
    private var inFence = false
    /// Rest of the line that opened a fence (its language tag).
    private var skippingLine = false
    private var ticks = 0

    mutating func take(_ piece: String) -> String {
        var out = ""
        for character in piece {
            if character == "`" {
                ticks += 1
                continue
            }
            if ticks >= 3 {
                inFence.toggle()
                skippingLine = inFence
            } else if ticks > 0, !inFence {
                out += String(repeating: "`", count: ticks)
            }
            ticks = 0
            if skippingLine {
                if character == "\n" { skippingLine = false }
                continue
            }
            if !inFence { out.append(character) }
        }
        return out
    }
}

extension CallError: Equatable {
    static func == (lhs: CallError, rhs: CallError) -> Bool {
        switch (lhs, rhs) {
        case (.synthesisRefused, .synthesisRefused), (.noKey, .noKey), (.noAnswer, .noAnswer): true
        case let (.synthesis(a, b), .synthesis(c, d)): a == c && b == d
        case let (.microphone(a), .microphone(b)): a == b
        default: false
        }
    }
}

extension Array where Element == TimelineItem {
    /// The text of the last answer, for a call's first context.
    var lastAssistantText: String? {
        for item in reversed() {
            if case .assistant(_, let blocks, _, _) = item {
                let text = blocks.compactMap { block -> String? in if case .text(_, let text) = block { text } else { nil } }.joined()
                if !text.isEmpty { return text }
            }
        }
        return nil
    }
}
