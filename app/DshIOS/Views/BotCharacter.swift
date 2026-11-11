import SwiftUI

/// A Bot's built-in look: a flat shape with two eyes, drawn here. The ids are the shape names
/// ds-bot keeps for a Bot (`avatar.shape`), so a look picked here names the same shape there;
/// the drawings and the way they move are this app's own.
struct BotCharacter: Identifiable {
    /// The point between the eyes, how far apart their centres are, and the size of one.
    struct Eyes {
        var x: Double
        var y: Double
        var gap = 24.0
        var width = 11.5
        var height = 20.0
    }

    /// A lighter or darker patch on the body (white or black, at an opacity), kept inside it.
    struct Patch {
        let path: Path
        var dark = false
        var opacity = 0.2
    }

    let id: String
    /// In a 100-unit box.
    let body: Path
    let eyes: Eyes
    var patches: [Patch] = []

    private static let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func named(_ id: String?) -> BotCharacter? { id.flatMap { byId[$0] } }

    /// The looks a new Bot starts with, and the ones a Bot that was given none is drawn as.
    static let friendly = ["gumdrop", "kitty", "bunny", "star", "cushion", "peanut", "acorn", "beacon"]

    /// The same number for the same text on every launch (`hashValue` is not).
    static func stableHash(_ text: String) -> Int {
        text.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xff_ffff }
    }

    /// The look of a Bot that was given none: one of the friendly ones, by its id.
    static func fallback(for id: String) -> BotCharacter {
        named(friendly[stableHash(id) % friendly.count])!
    }

    static let all: [BotCharacter] = [
        BotCharacter(id: "gumdrop", body: Draw.join(Draw.circle(50, 50, 38), Draw.box(12, 50, 76, 38, 13)), eyes: Eyes(x: 50, y: 52)),
        BotCharacter(id: "kitty",
                     body: Draw.join(Path(ellipseIn: CGRect(x: 11, y: 30, width: 78, height: 60)),
                                     Draw.polygon([(14, 54), (19, 10), (47, 36)], radius: 5), Draw.polygon([(86, 54), (81, 10), (53, 36)], radius: 5)),
                     eyes: Eyes(x: 50, y: 61, gap: 26)),
        BotCharacter(id: "bunny",
                     body: Draw.join(Draw.circle(50, 62, 30), Draw.turned(Draw.box(27, 4, 16, 46, 8), by: -9, about: (35, 50)),
                                     Draw.turned(Draw.box(57, 4, 16, 46, 8), by: 9, about: (65, 50))),
                     eyes: Eyes(x: 50, y: 63, gap: 22, width: 10.5, height: 18)),
        BotCharacter(id: "star", body: Draw.star(points: 5, outer: 46, inner: 27, centre: (50, 53), radius: 8), eyes: Eyes(x: 50, y: 56, gap: 19, width: 9.5, height: 16)),
        BotCharacter(id: "cushion",
                     body: Draw.blob([(13, 13), (50, 21), (87, 13), (79, 50), (87, 87), (50, 79), (13, 87), (21, 50)]),
                     eyes: Eyes(x: 50, y: 50)),
        BotCharacter(id: "peanut", body: Draw.join(Draw.circle(50, 33, 24), Draw.circle(50, 64, 29)), eyes: Eyes(x: 50, y: 35, gap: 18, width: 9, height: 15)),
        BotCharacter(id: "acorn",
                     body: Draw.join(Path(ellipseIn: CGRect(x: 21, y: 38, width: 58, height: 56)), Draw.cap, Draw.box(46, 3, 8, 18, 4)),
                     eyes: Eyes(x: 50, y: 71, gap: 21, width: 9.5, height: 15),
                     patches: [Patch(path: Draw.join(Draw.cap, Draw.box(46, 3, 8, 18, 4)), dark: true, opacity: 0.16)]),
        BotCharacter(id: "beacon",
                     body: Draw.join(Draw.box(15, 34, 70, 56, 17), Draw.box(47, 14, 6, 24, 3), Draw.circle(50, 13, 8.5)),
                     eyes: Eyes(x: 50, y: 61, gap: 26),
                     patches: [Patch(path: Draw.circle(50, 13, 8.5), opacity: 0.45)]),
        BotCharacter(id: "squircle", body: Draw.superellipse(centre: (50, 50), radius: 41, power: 4.2), eyes: Eyes(x: 50, y: 50)),
        BotCharacter(id: "hex", body: Draw.star(points: 3, outer: 45, inner: 45, centre: (50, 50), radius: 10), eyes: Eyes(x: 50, y: 50)),
        BotCharacter(id: "moon",
                     body: Draw.circle(50, 50, 42).subtracting(Draw.circle(75, 31, 33)),
                     eyes: Eyes(x: 36, y: 62, gap: 15, width: 8.5, height: 14)),
        BotCharacter(id: "wave", body: Draw.hemmed, eyes: Eyes(x: 50, y: 45)),
        BotCharacter(id: "zed",
                     body: Draw.polygon([(36, 7), (77, 7), (61, 39), (85, 39), (35, 95), (45, 57), (17, 57)], radius: 5),
                     eyes: Eyes(x: 48, y: 48, gap: 16, width: 8.5, height: 14)),
        BotCharacter(id: "saucer",
                     body: Draw.join(Path(ellipseIn: CGRect(x: 5, y: 46, width: 90, height: 34)), Draw.circle(50, 45, 25)),
                     eyes: Eyes(x: 50, y: 42, gap: 18, width: 9, height: 15),
                     patches: [Patch(path: Path(ellipseIn: CGRect(x: 5, y: 46, width: 90, height: 34)), dark: true, opacity: 0.14)]),
        BotCharacter(id: "plus", body: Draw.join(Draw.box(33, 9, 34, 82, 12), Draw.box(9, 33, 82, 34, 12)), eyes: Eyes(x: 50, y: 50, gap: 18, width: 9.5, height: 16)),
        BotCharacter(id: "magnet",
                     body: Draw.join(Draw.box(14, 9, 72, 48, 7), Draw.circle(50, 54, 36)).subtracting(Draw.join(Draw.box(38, 0, 24, 50, 0), Draw.circle(50, 50, 12))),
                     eyes: Eyes(x: 50, y: 76, gap: 20, width: 9, height: 14),
                     patches: [Patch(path: Draw.box(10, 5, 80, 17, 0), opacity: 0.55)]),
        BotCharacter(id: "pebbles", body: Draw.join(Draw.circle(50, 65, 28), Draw.circle(29, 36, 17), Draw.circle(67, 30, 20)), eyes: Eyes(x: 50, y: 67, gap: 22, width: 10.5, height: 18)),
        BotCharacter(id: "ring", body: Draw.circle(50, 52, 41).subtracting(Draw.circle(50, 31, 11)), eyes: Eyes(x: 50, y: 64, gap: 24, width: 10.5, height: 18)),
        BotCharacter(id: "gem",
                     body: Draw.polygon([(30, 13), (70, 13), (93, 40), (50, 93), (7, 40)], radius: 7),
                     eyes: Eyes(x: 50, y: 50, gap: 22, width: 10, height: 17),
                     patches: [Patch(path: Draw.box(0, 0, 100, 34, 0), opacity: 0.22)]),
        BotCharacter(id: "whale",
                     body: Draw.join(Draw.blob([(20, 60), (32, 37), (58, 27), (84, 39), (91, 60), (72, 80), (38, 81)]),
                                     Draw.polygon([(24, 62), (5, 33), (19, 38), (29, 25), (36, 54)], radius: 4)),
                     eyes: Eyes(x: 64, y: 55, gap: 18, width: 8.5, height: 14)),
    ]
}

/// The pieces the shapes are made of.
private enum Draw {
    static func circle(_ x: Double, _ y: Double, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ radius: Double) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius, style: .continuous)
    }

    static func join(_ first: Path, _ others: Path...) -> Path {
        others.reduce(first) { $0.union($1) }
    }

    static func turned(_ path: Path, by degrees: Double, about pivot: (Double, Double)) -> Path {
        path.applying(CGAffineTransform(translationX: pivot.0, y: pivot.1).rotated(by: degrees * .pi / 180).translatedBy(x: -pivot.0, y: -pivot.1))
    }

    /// A polygon with its corners rounded.
    static func polygon(_ points: [(Double, Double)], radius: Double) -> Path {
        let corners = points.map { CGPoint(x: $0.0, y: $0.1) }
        var path = Path()
        let last = corners[corners.count - 1]
        path.move(to: CGPoint(x: (last.x + corners[0].x) / 2, y: (last.y + corners[0].y) / 2))
        for (index, corner) in corners.enumerated() {
            path.addArc(tangent1End: corner, tangent2End: corners[(index + 1) % corners.count], radius: radius)
        }
        path.closeSubpath()
        return path
    }

    /// A star, pointing up; with `inner` equal to `outer` it is a polygon of twice the points.
    static func star(points: Int, outer: Double, inner: Double, centre: (Double, Double), radius: Double) -> Path {
        polygon((0..<points * 2).map { index in
            let reach = index.isMultiple(of: 2) ? outer : inner
            let angle = Double(index) * .pi / Double(points) - .pi / 2
            return (centre.0 + reach * cos(angle), centre.1 + reach * sin(angle))
        }, radius: radius)
    }

    /// A closed curve that passes smoothly through the points.
    static func blob(_ points: [(Double, Double)]) -> Path {
        let knots = points.map { CGPoint(x: $0.0, y: $0.1) }
        let count = knots.count
        var path = Path()
        path.move(to: knots[0])
        for index in 0..<count {
            let before = knots[(index + count - 1) % count], from = knots[index], to = knots[(index + 1) % count], after = knots[(index + 2) % count]
            path.addCurve(to: to,
                          control1: CGPoint(x: from.x + (to.x - before.x) / 6, y: from.y + (to.y - before.y) / 6),
                          control2: CGPoint(x: to.x - (after.x - from.x) / 6, y: to.y - (after.y - from.y) / 6))
        }
        path.closeSubpath()
        return path
    }

    static func superellipse(centre: (Double, Double), radius: Double, power: Double) -> Path {
        var path = Path()
        for step in 0..<72 {
            let angle = Double(step) / 72 * 2 * .pi
            let x = cos(angle), y = sin(angle)
            let point = CGPoint(x: centre.0 + radius * (x < 0 ? -1 : 1) * pow(abs(x), 2 / power), y: centre.1 + radius * (y < 0 ? -1 : 1) * pow(abs(y), 2 / power))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// The acorn's cap: a wide dome over the nut.
    static let cap = join(box(11, 27, 78, 27, 13), Path(ellipseIn: CGRect(x: 15, y: 14, width: 70, height: 36)))

    /// A dome with a scalloped hem.
    static let hemmed: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 14, y: 89))
        path.addLine(to: CGPoint(x: 14, y: 46))
        path.addArc(center: CGPoint(x: 50, y: 46), radius: 36, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: 86, y: 89))
        for edge in [62.0, 38, 14] {
            path.addQuadCurve(to: CGPoint(x: edge, y: 89), control: CGPoint(x: edge + 12, y: 71))
        }
        path.closeSubpath()
        return path
    }()
}

/// The colours a Bot can have, by ds-bot's colour names.
enum BotInk {
    /// The plugin's colour names and the ink its own window paints them in (light appearance).
    static let hexes: [String: String] = [
        "deepseek": "#4D6BFE", "charcoal": "#141416", "graphite": "#2D2D2D", "rose": "#EC2F6B", "sky": "#0AA8D6",
        "tangerine": "#FF6900", "cobalt": "#082DFF", "black": "#000000", "brown": "#9A6B44", "red": "#FF3E51",
        "orange": "#FF6B1A", "yellow": "#FFB020", "green": "#10B981", "cyan": "#06B6D4", "blue": "#2563EB",
        "violet": "#8B5CF6", "magenta": "#F43F85", "gray": "#8A8F98", "aurora": "#00B8D4",
    ]

    /// The near-blacks would vanish on a dark page: there they turn to light greys.
    private static let onDark: [String: String] = ["black": "#ECECEF", "charcoal": "#DCDCE1", "graphite": "#C6C6CC"]

    private static let colors: [String: Color] = Dictionary(uniqueKeysWithValues: hexes.map { key, hex in
        let light = UIColor(Color(hex: hex)!), dark = UIColor(Color(hex: onDark[key] ?? hex)!)
        return (key, Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light }))
    })

    /// A colour name's ink, or a hex of the user's own; nil for neither.
    static func color(_ key: String?) -> Color? {
        guard let key else { return nil }
        return colors[key] ?? Color(hex: key)
    }
}

/// What a Bot is doing, which picks how its mark moves.
enum BotMood: Equatable {
    case idle, thinking, searching, working
    /// It is handing work to another Bot.
    case sending
    /// It handed work on and waits for it to come back.
    case waiting
    /// Something waits on the user.
    case alert
}

/// How a mark stands at one moment.
private struct Pose {
    /// In units of the 100-unit box.
    var dx = 0.0, dy = 0.0
    /// Degrees.
    var tilt = 0.0
    var stretchX = 1.0, stretchY = 1.0
    /// Turns about its middle (a spin), else about its feet.
    var centred = false
    /// Where the pupils look: -1…1 across and down.
    var gazeX = 0.0, gazeY = 0.15
    /// How open the eyes are: 1 is open.
    var lid = 1.0
    /// The eyes closed in a smile.
    var happy = false

    /// 0 at both ends of 0…1, 1 in the middle: the height of a hop.
    static func arc(_ progress: Double) -> Double { 4 * progress * (1 - progress) }

    static func ease(_ progress: Double) -> Double {
        let x = min(1, max(0, progress))
        return x * x * (3 - 2 * x)
    }

    static func cycle(_ time: Double, _ period: Double) -> Double {
        let phase = (time / period).truncatingRemainder(dividingBy: 1)
        return phase < 0 ? phase + 1 : phase
    }

    /// The lids shut and open again once every `every` seconds.
    static func blink(_ time: Double, every: Double) -> Double {
        let since = cycle(time, every) * every
        return since < 0.18 ? max(0.08, abs(since / 0.09 - 1)) : 1
    }

    /// A hop with a squash on landing.
    mutating func hop(_ progress: Double, height: Double) {
        let lift = Self.arc(progress), ground = max(0, 1 - min(progress, 1 - progress) * 7)
        dy = -height * lift
        stretchY = 1 + 0.05 * lift - 0.09 * ground
        stretchX = 1 - 0.035 * lift + 0.07 * ground
    }

    static func make(mood: BotMood, lively: Bool, seed: Int, time: Double) -> Pose {
        var pose = Pose()
        switch mood {
        case .idle:
            // Still, unless it is one of the large ones: those breathe, blink and glance aside now and then.
            guard lively else { break }
            let own = time + Double(seed % 4000) / 1000
            let breath = sin(own * 2 * .pi / 3.4)
            pose.stretchY = 1 + 0.018 * breath
            pose.stretchX = 1 - 0.012 * breath
            pose.lid = blink(own, every: 4.6)
            let glance = cycle(own * 1.3, 7.5) * 7.5
            if glance < 1.6 { pose.gazeX = (seed.isMultiple(of: 2) ? 1 : -1) * ease(glance * 4) * ease((1.6 - glance) * 4) }
        case .thinking:
            // Head to one side, eyes up and narrowed.
            let sway = sin(time * 2 * .pi / 3)
            pose.tilt = 5 + 2.5 * sway
            pose.dy = -1.5 - 1.5 * sway
            pose.gazeX = 0.7 + 0.2 * sin(time * .pi / 3)
            pose.gazeY = -0.75
            pose.lid = 0.78 * blink(time, every: 3.8)
        case .searching:
            // Looking from side to side, leaning after its eyes.
            let side = sin(time * 2 * .pi / 1.5)
            pose.gazeX = side
            pose.dx = 2.2 * side
            pose.tilt = 3.5 * side
        case .working:
            // Bouncing in place, eyes on the job.
            pose.hop(cycle(time, 0.86), height: 6.5)
            pose.gazeY = 0.4
            pose.lid = blink(time, every: 2.58)
        case .sending:
            // A push forward, quick out and slow back.
            let step = cycle(time, 1.25)
            let push = ease(step * 2.5) * (1 - ease((step - 0.4) / 0.6))
            pose.dx = 6 * push
            pose.tilt = 7 * push
            pose.gazeX = 0.85
        case .waiting:
            // Rocking slowly, eyes half shut.
            let rock = sin(time * 2 * .pi / 4)
            pose.tilt = 4.5 * rock
            pose.gazeX = 0.5 * rock
            pose.gazeY = 0.25
            pose.lid = 0.6 * blink(time, every: 5.2)
        case .alert:
            // Wide-eyed, looking up at the reader. It hops as the question arrives (`BotMark.Act`).
            pose.gazeY = -0.25
            pose.lid = 1.12
        }
        return pose
    }
}

/// A Bot's character in its colour, moving for what the Bot is doing. A resting mark is still
/// unless it is `lively` (the large marks); Reduce Motion keeps every mark still.
struct BotMark: View {
    let character: BotCharacter
    let color: Color
    var size: CGFloat = 40
    var mood = BotMood.idle
    var lively = false
    /// Sets each Bot's blinks and glances at its own moment: the Bot's id.
    var seed = ""
    /// Each change spins the mark once, eyes shut in a smile.
    var poke = 0
    /// Draws the page behind the mark's edge, so marks that overlap stay apart.
    var outline: Color?
    /// A ring around the silhouette: the picked look.
    var ringed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var act: Act?

    /// A move played once, over whatever the mood does: a happy hop as a run ends, two hops as
    /// a question arrives, a spin when poked.
    private struct Act: Equatable {
        enum Kind { case settle, hops, poke }
        let kind: Kind
        let at = Date.now

        var length: Double {
            switch kind {
            case .settle: 1
            case .hops: 1.1
            case .poke: 0.75
            }
        }
    }

    var body: some View {
        let moving = !reduceMotion && (lively || act != nil || (mood != .idle && mood != .alert))
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
            drawing(pose(at: timeline.date))
        }
        // Room for a hop or a lean beyond the mark's own box.
        .frame(width: size * 1.5, height: size * 1.5)
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .onAppear { if mood == .alert { act = Act(kind: .hops) } }
        .onChange(of: mood) { old, new in turned(from: old, to: new) }
        .onChange(of: poke) { act = Act(kind: .poke) }
        .task(id: act) { await finishAct() }
    }

    private func turned(from old: BotMood, to new: BotMood) {
        if new == .alert {
            act = Act(kind: .hops)
        } else if new == .idle, old != .alert {
            act = Act(kind: .settle)
        } else {
            act = nil
        }
    }

    /// Once the move has played the mark is back to what its mood does (a resting one stops redrawing).
    private func finishAct() async {
        guard let playing = act else { return }
        try? await Task.sleep(for: .seconds(playing.length))
        if !Task.isCancelled { act = nil }
    }

    private func pose(at date: Date) -> Pose {
        guard !reduceMotion else { return Pose() }
        var pose = Pose.make(mood: mood, lively: lively, seed: BotCharacter.stableHash(seed), time: date.timeIntervalSinceReferenceDate)
        guard let act else { return pose }
        let elapsed = date.timeIntervalSince(act.at)
        guard elapsed < act.length else { return pose }
        switch act.kind {
        case .settle:
            pose = Pose(happy: true)
            if elapsed < 0.45 { pose.hop(elapsed / 0.45, height: 7) }
        case .hops:
            pose.hop(Pose.cycle(elapsed, 0.55), height: 11)
        case .poke:
            let turn = elapsed / act.length
            pose = Pose(dy: -9 * Pose.arc(turn), tilt: 360 * (1 - pow(1 - turn, 3)), centred: true, happy: true)
        }
        return pose
    }

    private func drawing(_ pose: Pose) -> some View {
        let character = character
        let fill = GraphicsContext.Shading.color(color)
        return Canvas { context, _ in
            context.translateBy(x: size * 0.25, y: size * 0.25)
            context.scaleBy(x: size / 100, y: size / 100)
            let box = character.body.boundingRect
            let pivot = CGPoint(x: box.midX, y: pose.centred ? box.midY : box.maxY)
            context.translateBy(x: pivot.x + pose.dx, y: pivot.y + pose.dy)
            context.rotate(by: .degrees(pose.tilt))
            context.scaleBy(x: pose.stretchX, y: pose.stretchY)
            context.translateBy(x: -pivot.x, y: -pivot.y)
            if ringed { context.drawLayer { Self.ring(&$0, body: character.body, fill: fill) } }
            if let outline { context.stroke(character.body, with: .color(outline), style: StrokeStyle(lineWidth: 10, lineJoin: .round)) }
            context.fill(character.body, with: fill)
            if !character.patches.isEmpty { context.drawLayer { Self.patches(&$0, character) } }
            Self.eyes(&context, character.eyes, pose: pose)
        }
    }

    /// A ring around the silhouette, apart from it by a gap.
    private static func ring(_ layer: inout GraphicsContext, body: Path, fill: GraphicsContext.Shading) {
        layer.stroke(body, with: fill, style: StrokeStyle(lineWidth: 22, lineJoin: .round))
        layer.blendMode = .destinationOut
        layer.stroke(body, with: .color(.black), style: StrokeStyle(lineWidth: 12, lineJoin: .round))
        layer.fill(body, with: .color(.black))
    }

    private static func patches(_ layer: inout GraphicsContext, _ character: BotCharacter) {
        layer.clip(to: character.body)
        for patch in character.patches {
            layer.fill(patch.path, with: .color((patch.dark ? Color.black : Color.white).opacity(patch.opacity)))
        }
    }

    /// Two white eyes whose pupils follow the gaze; shut in a smile, two arcs.
    private static func eyes(_ context: inout GraphicsContext, _ eyes: BotCharacter.Eyes, pose: Pose) {
        let white = GraphicsContext.Shading.color(.white), dark = GraphicsContext.Shading.color(Color(white: 0.08))
        for side in [-0.5, 0.5] {
            let centre = CGPoint(x: eyes.x + side * eyes.gap, y: eyes.y)
            if pose.happy {
                var smile = Path()
                smile.move(to: CGPoint(x: centre.x - eyes.width * 0.75, y: centre.y + eyes.height * 0.14))
                smile.addQuadCurve(to: CGPoint(x: centre.x + eyes.width * 0.75, y: centre.y + eyes.height * 0.14),
                                   control: CGPoint(x: centre.x, y: centre.y - eyes.height * 0.5))
                context.stroke(smile, with: white, style: StrokeStyle(lineWidth: eyes.width * 0.5, lineCap: .round))
                continue
            }
            let height: Double = eyes.height * pose.lid
            let socket = CGRect(x: centre.x - eyes.width / 2, y: centre.y - height / 2, width: eyes.width, height: height)
            context.fill(Path(roundedRect: socket, cornerRadius: min(eyes.width, height) / 2), with: white)
            let pupil: Double = eyes.width * 0.62
            guard height > pupil else { continue }
            let reachX: Double = (eyes.width - pupil) / 2 - 0.3, reachY: Double = max(0, (height - pupil) / 2 - 0.6)
            let spot = CGPoint(x: centre.x + pose.gazeX * reachX, y: centre.y + pose.gazeY * reachY)
            context.fill(Path(ellipseIn: CGRect(x: spot.x - pupil / 2, y: spot.y - pupil / 2, width: pupil, height: pupil)), with: dark)
        }
    }
}

/// A photo or the app's mascot as a Bot's mark: it has no eyes to move, so it bounces while the
/// Bot is busy and hops twice when something waits on the user.
struct BotPictureMotion: ViewModifier {
    let mood: BotMood
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hopsFrom: Date?

    func body(content: Content) -> some View {
        let busy = mood != .idle && mood != .alert
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !(busy || hopsFrom != nil))) { timeline in
            let stance = pose(at: timeline.date, busy: busy)
            content
                .scaleEffect(x: stance.stretchX, y: stance.stretchY, anchor: .bottom)
                .offset(y: stance.dy * size / 100)
        }
        .onAppear { if mood == .alert { hopsFrom = .now } }
        .onChange(of: mood) { hopsFrom = mood == .alert ? .now : nil }
        .task(id: hopsFrom) {
            guard hopsFrom != nil else { return }
            try? await Task.sleep(for: .seconds(1.1))
            if !Task.isCancelled { hopsFrom = nil }
        }
    }

    private func pose(at date: Date, busy: Bool) -> Pose {
        var pose = Pose()
        if reduceMotion { return pose }
        if let hopsFrom {
            pose.hop(Pose.cycle(date.timeIntervalSince(hopsFrom), 0.55), height: 11)
        } else if busy {
            pose.hop(Pose.cycle(date.timeIntervalSinceReferenceDate, 0.86), height: 5)
        }
        return pose
    }
}

extension BotModel {
    /// A Bot's character: the one it was given, else one its id picks.
    func character(of bot: BotInfo) -> BotCharacter {
        BotCharacter.named(bot.json["avatar"]["shape"].string) ?? BotCharacter.fallback(for: bot.id)
    }

    /// How a Bot's mark moves right now, from what it is doing (`activity`).
    func mood(_ botId: String) -> BotMood {
        switch activity[botId]?.string {
        case nil, "idle": .idle
        case "alert": .alert
        case "waiting": .waiting
        case "thinking": .thinking
        default: .working
        }
    }
}
