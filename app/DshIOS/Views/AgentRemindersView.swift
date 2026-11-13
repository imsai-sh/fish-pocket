import SwiftUI
import UserNotifications

/// One thing the agent set to go off on this phone: an alarm (`alarm`, AlarmKit) or a
/// local notification (`notify`).
///
/// iOS shows neither anywhere before it goes off: the Clock app lists only its own
/// alarms and there is no list of pending notifications. So 自动化 › 提醒 is the one place
/// the user can see what is waiting and take it back.
struct AgentReminder: Identifiable, Equatable {
    enum Kind { case alarm, notification }

    let id: String
    let kind: Kind
    let title: String
    let body: String?
    /// The next time it goes off; nil while an alarm is ringing.
    let next: Date?
    /// An alarm's rule (`仅一次` / `每天 09:00` / `每周一、五 09:00`); nil for notifications.
    let rule: String?
    let ringing: Bool

    /// The identifiers `caps_notify.m` gives the agent's notifications; the app's own
    /// (a Bot waiting on the user) do not carry it and are not listed.
    static let notificationPrefix = "dsh.agent."

    /// The next wall-clock `hour:minute` after `now`, on one of `weekdays` (ISO, Monday 1 …
    /// Sunday 7) when there are any — AlarmKit only keeps the rule, not the next date.
    static func nextOccurrence(hour: Int, minute: Int, weekdays: [Int], after now: Date, calendar: Calendar = .current) -> Date? {
        var time = DateComponents()
        time.hour = hour
        time.minute = minute
        time.second = 0
        guard !weekdays.isEmpty else {
            return calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime)
        }
        return weekdays.compactMap { iso in
            var components = time
            components.weekday = iso % 7 + 1 // Calendar counts from Sunday 1.
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
        }.min()
    }
}

/// The alarms and notifications, read straight from iOS each time: nothing is cached, so the
/// list cannot disagree with what will actually go off.
@MainActor
@Observable
final class AgentReminders {
    private(set) var items: [AgentReminder] = []
    /// A read has finished at least once.
    private(set) var settled = false

    /// The soonest time something goes off, to re-read once it has.
    var soonest: Date? { items.compactMap(\.next).min() }

    func load() async {
        let notifications = await Self.notifications()
        let alarms = AlarmProvider.reminders()
        // Ringing first, then by time.
        items = (alarms + notifications).sorted { ($0.next ?? .distantPast) < ($1.next ?? .distantPast) }
        settled = true
    }

    func delete(_ item: AgentReminder) async -> Bool {
        switch item.kind {
        case .notification:
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.id])
        case .alarm:
            guard AlarmProvider.remove(item.id) else { return false }
        }
        await load()
        return true
    }

    private static func notifications() async -> [AgentReminder] {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.filter { $0.identifier.hasPrefix(AgentReminder.notificationPrefix) }.map { request in
            let content = request.content
            // `caps_notify.m` titles an untitled one with the app's name; the text is what it is about.
            let titled = !content.title.isEmpty && content.title != "Fish Pocket"
            return AgentReminder(
                id: request.identifier,
                kind: .notification,
                title: titled ? content.title : content.body,
                body: titled && !content.body.isEmpty ? content.body : nil,
                next: (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                    ?? (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
                rule: nil,
                ringing: false
            )
        }
    }
}

/// 自动化 › 提醒: the agent's alarms and notifications, soonest first; swipe to delete.
/// `query` is the page's search text.
struct AgentRemindersList: View {
    var query: String = ""

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var reminders = AgentReminders()
    @State private var confirming: AgentReminder?

    private var shown: [AgentReminder] {
        let needle = query.trimmed.lowercased()
        guard !needle.isEmpty else { return reminders.items }
        return reminders.items.filter { item in
            [item.title, item.body ?? ""].contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(shown) { item in
                    AgentReminderRow(item: item)
                        .swipeActions {
                            Button(role: .destructive) { confirming = item } label: { Label("删除", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button(role: .destructive) { confirming = item } label: { Label("删除", systemImage: "trash") }
                        }
                }
            } footer: {
                if !shown.isEmpty {
                    Text("智能体设的闹钟和通知。iOS 不会把它们放进「时钟」App，只能在这里查看和删除。")
                }
            }
            .groupedRow()
        }
        .overlay { overlay }
        .groupedList()
        .refreshable { await reminders.load() }
        .task { await reminders.load() }
        .task {
            for await _ in AlarmProvider.changes() { await reminders.load() }
        }
        // Gone once it has gone off: a one-off alarm or a delivered notification leaves iOS's list.
        .task(id: reminders.soonest) {
            guard let soonest = reminders.soonest else { return }
            try? await Task.sleep(for: .seconds(max(soonest.timeIntervalSinceNow + 2, 5)))
            guard !Task.isCancelled else { return }
            await reminders.load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reminders.load() } }
        }
        .confirmationDialog(
            confirming?.kind == .alarm ? Text("删除这个闹钟？") : Text("删除这条通知？"),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { item in
            Button("确认删除", role: .destructive) { Task { await delete(item) } }
            Button("取消", role: .cancel) {}
        } message: { item in
            if item.kind == .alarm {
                Text("「\(item.title)」\n删除后到时间不会再响。")
            } else {
                Text("「\(item.title)」\n删除后不会再收到这条通知。")
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if !reminders.settled {
            ProgressView()
        } else if shown.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "alarm")
            } description: {
                if reminders.items.isEmpty {
                    Text("在对话里让智能体设闹钟或定时通知，例如「明早 7 点叫我起床」，会列在这里。iOS 不会把它们放进「时钟」App。")
                }
            }
        }
    }

    private var emptyTitle: LocalizedStringKey {
        reminders.items.isEmpty ? "还没有提醒" : "没有匹配的提醒"
    }

    private func delete(_ item: AgentReminder) async {
        if await reminders.delete(item) {
            Haptics.success()
            app.showToast(item.kind == .alarm ? String(localized: "闹钟已删除") : String(localized: "通知已删除"))
        } else {
            Haptics.error()
            app.showToast(String(localized: "无法删除闹钟"))
        }
    }
}

/// One reminder: kind and title, the rule (alarms), the text (titled notifications), then when.
struct AgentReminderRow: View {
    let item: AgentReminder

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: item.kind == .alarm ? "alarm" : "bell")
                .foregroundStyle(item.kind == .alarm ? Palette.waiting : Color.accentColor)
                .frame(width: 22)
                .accessibilityLabel(item.kind == .alarm ? Text("闹钟") : Text("通知"))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.callout).foregroundStyle(Palette.ink).lineLimit(2)
                if let line = subtitle {
                    Text(line).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(2)
                }
                if item.ringing {
                    Text("正在响").font(.caption.weight(.semibold)).foregroundStyle(Palette.waiting)
                } else if let next = item.next {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let when = ScheduleFormat.nextRun(next, now: context.date)
                        Group {
                            if item.kind == .alarm {
                                Text("下次响铃：\(when)")
                            } else {
                                Text("送达时间：\(when)")
                            }
                        }
                        .font(.caption).foregroundStyle(Palette.faint).monospacedDigit()
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String? {
        switch item.kind {
        case .alarm: item.rule
        case .notification: item.body
        }
    }
}
