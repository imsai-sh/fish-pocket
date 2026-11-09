import SwiftUI

/// Whose tasks a schedule section lists: a Bot's own chat or a group chat.
enum BotScheduleTarget: Equatable {
    case bot(String)
    case room(String)

    var id: String {
        switch self {
        case .bot(let id), .room(let id): id
        }
    }

    /// One of ds-bot's `schedules` entries belongs here: a Bot's own chat (`botId` alone)
    /// or a group's own Session (`roomId` alone), not a member's hidden group Session.
    func owns(_ task: JSON) -> Bool {
        switch self {
        case .bot(let id): task["botId"].string == id && task["roomId"].isNull
        case .room(let id): task["roomId"].string == id && task["botId"].isNull
        }
    }
}

/// The scheduled tasks of a Bot or a group, read from ds-bot. Owned by the page that shows
/// them, which also presents the new-task sheet: a section's modifiers would go to every row.
@MainActor
@Observable
final class BotSchedules {
    let target: BotScheduleTarget
    private(set) var tasks: [JSON] = []
    private(set) var available = true
    private(set) var loaded = false
    var creating = false
    let catalog = ScheduleCatalog()

    init(target: BotScheduleTarget) { self.target = target }

    func load(_ app: AppModel) async {
        if let value = try? await app.botTeam.call("schedules") { apply(value) } else { loaded = true }
        await catalog.load(app.client)
    }

    func apply(_ value: JSON) {
        available = value["available"].bool ?? false
        tasks = value["tasks"].array.filter(target.owns)
            .sorted { (ScheduleFormat.date($0["scheduledAt"].string) ?? .distantFuture) < (ScheduleFormat.date($1["scheduledAt"].string) ?? .distantFuture) }
        loaded = true
    }

    /// `task` is ds-bot's entry, or DSH's own (the detail page's), whose Session is its target's.
    func delete(_ task: JSON, app: AppModel) async -> Bool {
        Haptics.firm()
        let entry = tasks.first { $0["id"] == task["id"] } ?? task
        let sessionId = entry["sessionId"].string ?? entry["target"]["sessionId"].string ?? ""
        do {
            let value = try await app.botTeam.call("schedule-delete", ["id": entry["id"], "sessionId": .string(sessionId)])
            apply(value)
            app.showToast(String(localized: "任务已删除"))
            return true
        } catch {
            app.showToast(error.localizedDescription, tone: .warning)
            return false
        }
    }
}

extension View {
    /// Reads a page's scheduled tasks and presents their new-task sheet.
    func botSchedules(_ schedules: BotSchedules, app: AppModel) -> some View {
        sheet(isPresented: Binding(get: { schedules.creating }, set: { schedules.creating = $0 })) {
            BotScheduleCreateSheet(target: schedules.target) { schedules.apply($0) }
        }
        .task(id: app.revision("schedule/changed")) { await schedules.load(app) }
    }
}

/// The tasks as rows. They are DSH's own tasks, so a row opens the same detail page as
/// 设置 › 自动化 (edit, pause, run history, delete); ds-bot adds creating one for the Bot
/// and follows it when the chat moves to a new part.
struct BotScheduleSection: View {
    @Environment(AppModel.self) private var app
    let schedules: BotSchedules

    var body: some View {
        Section {
            if !schedules.loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if !schedules.available {
                Text("自动化任务没有开启，Bot 用不了定时任务。").font(.footnote).foregroundStyle(Palette.secondary)
            } else {
                ForEach(schedules.tasks, id: \.["id"]) { task in
                    NavigationLink {
                        ScheduleDetailView(catalog: schedules.catalog, taskId: task["id"].string ?? "", withinSession: task["sessionId"].string,
                                           openSession: { _ in }, delete: { await schedules.delete($0, app: app) })
                    } label: {
                        ScheduleRow(record: task)
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { _ = await schedules.delete(task, app: app) } } label: { Label("删除", systemImage: "trash") }
                    }
                }
                Button { schedules.creating = true } label: { Label("新建定时任务", systemImage: "plus") }
            }
        } header: {
            // The Bot's page has a 定时任务 tab already.
            if case .room = schedules.target { Text("定时任务") }
        } footer: {
            if schedules.loaded && schedules.available {
                Text(schedules.tasks.isEmpty ? footerEmpty : "左滑可以删除。")
            }
        }
        .groupedRow()
    }

    private var footerEmpty: LocalizedStringKey {
        switch schedules.target {
        case .bot: "到点自动给它发一条指令，它就开工。"
        case .room: "到点自动在群里发一条指令，群里的 Bot 就开工。"
        }
    }
}

/// A new task for a Bot or a group: a name, what to do, and when.
struct BotScheduleCreateSheet: View {
    enum Repeat: String, CaseIterable, Identifiable {
        case once, daily, weekly, every
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .once: "一次"
            case .daily: "每天"
            case .weekly: "每周"
            case .every: "每隔一段时间"
            }
        }
    }

    enum Unit: Int, CaseIterable, Identifiable {
        case minutes = 1, hours = 60, days = 1440
        var id: Int { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .minutes: "分钟"
            case .hours: "小时"
            case .days: "天"
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: BotScheduleTarget
    let created: (JSON) -> Void

    @State private var title = ""
    @State private var prompt = ""
    @State private var repeatKind = Repeat.daily
    @State private var at = Date.now.addingTimeInterval(3600)
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    /// 1 = Monday … 7 = Sunday, as the plugin counts.
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var amount = 1
    @State private var unit = Unit.hours
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，比如：每日简报", text: $title)
                    TextField("到点要做什么", text: $prompt, axis: .vertical).lineLimit(3...)
                }
                Section {
                    Picker("重复", selection: $repeatKind) {
                        ForEach(Repeat.allCases) { Text($0.title).tag($0) }
                    }
                    switch repeatKind {
                    case .once:
                        DatePicker("时间", selection: $at, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    case .daily:
                        DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                    case .weekly:
                        DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                        weekdayPicker
                    case .every:
                        Stepper(value: $amount, in: 1...maxAmount) { Text("每 \(amount)") }
                        Picker("单位", selection: $unit) {
                            ForEach(Unit.allCases) { Text($0.title).tag($0) }
                        }
                    }
                } footer: {
                    Text("按这台设备的时区（\(TimeZone.current.identifier)）。")
                }
            }
            .navigationTitle("新建定时任务")
            .navigationBarTitleDisplayMode(.inline)
            .saveToolbar(canSave: canSave, saving: saving, cancel: { dismiss() }) { save() }
            .onChange(of: unit) { _, _ in amount = min(amount, maxAmount) }
        }
    }

    private var weekdayPicker: some View {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        return HStack(spacing: 6) {
            // Monday first; the calendar's symbols start on Sunday.
            ForEach(1...7, id: \.self) { day in
                let on = weekdays.contains(day)
                Button {
                    Haptics.select()
                    if on { weekdays.remove(day) } else { weekdays.insert(day) }
                } label: {
                    Text(symbols[day % 7])
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Palette.onInk : Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(on ? Palette.ink : Palette.control, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var maxAmount: Int { 10080 / unit.rawValue }

    private var canSave: Bool {
        let named = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 120
        let said = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let timed = repeatKind != .weekly || !weekdays.isEmpty
        return named && said && timed
    }

    private var when: JSON {
        let zone = JSON.string(TimeZone.current.identifier)
        let clock = time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
        switch repeatKind {
        case .once: return ["kind": "at", "at": .string(at.formatted(.iso8601))]
        case .daily: return ["kind": "daily", "time": .string(clock), "timeZone": zone]
        case .weekly: return ["kind": "weekly", "time": .string(clock), "timeZone": zone, "weekdays": .array(weekdays.sorted().map { .number(Double($0)) })]
        case .every: return ["kind": "every", "minutes": .number(Double(amount * unit.rawValue))]
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                let value = try await app.botTeam.call("schedule-create", [
                    "target": .string(target.id),
                    "title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "prompt": .string(prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "when": when,
                ])
                Haptics.success()
                created(value)
                dismiss()
            } catch {
                app.showToast(error.localizedDescription, tone: .warning)
            }
            saving = false
        }
    }
}
