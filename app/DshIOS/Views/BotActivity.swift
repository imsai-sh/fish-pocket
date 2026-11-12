import SwiftUI

/// The tail of a Bot's own chat while it works, in place of the session's 「深度求索中」: its
/// mark, moving for what it does, a phrase for it, and how long the turn has run. While its
/// answer streams the mark gives way to three dots.
struct BotActivityLine: View {
    @Environment(AppModel.self) private var app
    let botId: String
    let model: SessionModel
    @State private var arrived = false
    /// What the line shows. It follows `current` in an animation of its own, so the line's
    /// move down the page, as the reply above it grows, is not animated with it.
    @State private var line = Line(stage: .thinking, phrase: "")

    private enum Stage: Equatable {
        case typing
        case thinking
        /// A tool runs, by its name.
        case tool(String)
        /// It waits: for the user to allow a tool, or for work it handed on.
        case held(BotMood)

        var mood: BotMood? {
            switch self {
            case .typing: nil
            case .thinking: .thinking
            case .held(let mood): mood
            case .tool(let name):
                if Self.teamTools.contains(name) { .sending }
                else if [.read, .readImage, .search, .webSearch, .webFetch].contains(StepKind(tool: name)) { .searching }
                else { .working }
            }
        }

        /// ds-bot's tools that pass work to another Bot or a group.
        static let teamTools: Set<String> = ["message_bot", "stop_bot", "create_bot", "update_bot", "create_group", "update_group", "delete_group", "post_to_group"]
    }

    private struct Line: Equatable {
        var stage: Stage
        var phrase: String
    }

    var body: some View {
        let team = app.botTeam
        let bot = team.bot(botId)
        let current = current(team)
        HStack(spacing: 8) {
            ZStack {
                if let mood = line.stage.mood {
                    BotAvatar(bot: bot, size: 24, mood: mood).transition(.scale(scale: 0.2).combined(with: .opacity))
                } else {
                    BotTypingDots(color: bot.map(team.color(of:)) ?? Palette.secondary).transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .frame(width: 26, height: 24)
            // The mark grows out of a point, as the line arrives.
            .scaleEffect(arrived ? 1 : 0.1)
            // One phrase fades into the next in place.
            ZStack(alignment: .leading) { BotShimmer(text: line.phrase).id(line.phrase).transition(.opacity) }
            if let since = model.runningSince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(TimelineFormat.duration(max(1, Int(context.date.timeIntervalSince(since)))))
                        .font(.caption).monospacedDigit().foregroundStyle(Palette.faint)
                }
            }
        }
        .opacity(arrived ? 1 : 0)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .onChange(of: current, initial: true) { _, current in
            withAnimation(arrived ? .spring(response: 0.35, dampingFraction: 0.7) : nil) { line = current }
        }
        .task {
            // After the pass that laid the line out, so the whole of it is seen.
            await Task.yield()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { arrived = true }
        }
        .accessibilityElement(children: .combine)
    }

    private func current(_ team: BotModel) -> Line {
        let stage = stage(team)
        return Line(stage: stage, phrase: phrase(stage, team) + "…")
    }

    private func stage(_ team: BotModel) -> Stage {
        switch team.doing(botId) {
        case .approval: return .held(.alert)
        case .waiting: return .held(.waiting)
        default: break
        }
        if case .text? = model.live.last { return .typing }
        var blocks = model.live
        if blocks.isEmpty, case .assistant(_, let turn, _, _)? = model.items.last { blocks = turn }
        if case .tool(let call)? = blocks.last, !call.finished { return .tool(call.displayName) }
        return .thinking
    }

    /// What the step does, in the words the steps above use; the Bot's own words for it are its reply.
    private func phrase(_ stage: Stage, _ team: BotModel) -> String {
        switch stage {
        case .typing: return String(localized: "正在输入")
        case .thinking: return String(localized: "正在琢磨")
        case .held: return team.doingText(botId) ?? String(localized: "正在处理")
        case .tool(let name):
            if Stage.teamTools.contains(name) { return String(localized: "正在联系其他 Bot") }
            let kind = StepKind(tool: name)
            return kind == .tools ? String(localized: "正在处理") : kind.running
        }
    }
}

/// A member of a group speaking: its mark at work beside what it is doing.
struct BotSpeakingLine: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo

    var body: some View {
        let team = app.botTeam
        let mood = team.mood(bot.id)
        HStack(spacing: 8) {
            BotAvatar(bot: bot, size: 24, mood: mood == .idle ? .working : mood)
            BotShimmer(text: team.workPhrase(bot.id).map { "\(bot.name) · \($0)…" } ?? String(localized: "\(bot.name)正在输入…"))
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }
}

/// A line of work in progress: a light sweeps across the words.
struct BotShimmer: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                        // The band's middle, from before the first character to past the last.
                        let middle = (timeline.date.timeIntervalSinceReferenceDate / 1.8).truncatingRemainder(dividingBy: 1) * 1.8 - 0.4
                        Text(text).font(.footnote).foregroundStyle(Palette.ink).lineLimit(1)
                            .mask(LinearGradient(colors: [.clear, .black, .clear],
                                                 startPoint: UnitPoint(x: middle - 0.35, y: 0.5), endPoint: UnitPoint(x: middle + 0.35, y: 0.5)))
                    }
                    .accessibilityHidden(true)
                }
            }
    }
}

/// Three dots in the Bot's colour, swelling one after another: it is writing its answer.
struct BotTypingDots: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let turn: Double = (time * 1.5 - Double(index) * 0.2) * 2 * .pi
                    let swell: Double = reduceMotion ? 0.5 : (sin(turn) + 1) / 2
                    Circle().fill(color).frame(width: 6, height: 6)
                        .scaleEffect(0.65 + 0.5 * swell)
                        .opacity(0.4 + 0.6 * swell)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
