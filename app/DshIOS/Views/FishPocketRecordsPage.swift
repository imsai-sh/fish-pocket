import SwiftUI

/// Fish Pocket 账号 → 积分明细: what the credits went on, month by month and day by day, and
/// the credits that came in (purchases, grants) or went back (refunds). Days are Beijing days,
/// as the service counts them.
struct FishPocketRecordsPage: View {
    private enum Tab { case usage, history }

    @Environment(AppModel.self) private var app
    @Environment(\.systemLists) private var systemLists
    @State private var records: FishPocketRecords?
    @State private var tab = Tab.usage
    @State private var month = FishPocketMonth.current
    /// A day of the month picked on the chart or in the list: the summary shows that day.
    @State private var picked: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                tabs.padding(.bottom, 14)
                if let records {
                    switch tab {
                    case .usage: usage(records)
                    case .history: history(records)
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(systemLists ? Color(.systemGroupedBackground) : Palette.grouped)
        .navigationTitle("积分明细")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if records == nil { records = FishPocketRecords(account: app.fishPocket) }
        }
        .task(id: Load(records: records != nil, tab: tab, month: month)) {
            guard let records else { return }
            switch tab {
            case .usage: await records.load(month)
            case .history: if case .loaded = records.history {} else { await records.loadHistory() }
            }
        }
        .refreshable {
            guard let records else { return }
            switch tab {
            case .usage: await records.load(month, force: true)
            case .history: await records.loadHistory()
            }
        }
    }

    private struct Load: Equatable {
        let records: Bool
        let tab: Tab
        let month: FishPocketMonth
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 8) {
            pill("用量", .usage)
            pill("充值", .history)
        }
    }

    private func pill(_ title: LocalizedStringKey, _ item: Tab) -> some View {
        let on = tab == item
        return Button {
            guard !on else { return }
            Haptics.select()
            withAnimation(.snappy(duration: 0.2)) { tab = item }
        } label: {
            Text(title)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Palette.onInk : Palette.ink)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(on ? Palette.ink : Palette.control, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Usage

    @ViewBuilder
    private func usage(_ records: FishPocketRecords) -> some View {
        monthBar(records).padding(.bottom, 10)
        switch records.months[month] ?? .loading {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 236)
                .cardSurface()
        case .failed:
            retry { await records.load(month) }
        case .loaded(let result):
            summary(result).cardSurface()
            if result.days.isEmpty {
                empty(title: "这个月还没有用量", detail: "用 Fish Pocket 账号对话后，每天的消耗会显示在这里。")
            } else {
                section("每日用量")
                VStack(spacing: 0) {
                    ForEach(Array(result.days.reversed().enumerated()), id: \.element.id) { index, day in
                        if index > 0 { Divider().padding(.leading, 16) }
                        dayRow(day)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .cardSurface()
                footnote("按北京时间统计，语音通话、按住说话和语音消息的用量也算在内。扣费后这里随即更新。")
            }
        }
    }

    private func monthBar(_ records: FishPocketRecords) -> some View {
        let earliest = records.since ?? (records.months[month].isLoaded ? month : nil)
        return HStack {
            stepButton("chevron.left", label: "上个月", disabled: earliest.map { month <= $0 } ?? false) {
                month = month.previous
            }
            Spacer(minLength: 0)
            Text(monthTitle(month))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
            Spacer(minLength: 0)
            stepButton("chevron.right", label: "下个月", disabled: month >= FishPocketMonth.current) {
                month = month.next
            }
        }
        .padding(.horizontal, 2)
    }

    private func stepButton(_ icon: String, label: LocalizedStringKey, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            picked = nil
            action()
        } label: {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 32, height: 32)
                .background(Palette.control, in: Circle())
                .hitTarget()
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(Text(label))
    }

    private func summary(_ result: FishPocketUsageMonth) -> some View {
        let day = picked.flatMap { picked in result.days.first { $0.day == picked } }
        let shown = day?.usage ?? result.total
        return VStack(alignment: .leading, spacing: 2) {
            Group {
                if let day {
                    Text(dayTitle(day.day)).foregroundStyle(Palette.spot)
                } else {
                    Text(month == .current ? "本月消耗" : "当月消耗").foregroundStyle(Palette.secondary)
                }
            }
            .font(.footnote.weight(.medium))
            amount(shown.credits)
            if shown.requests > 0 {
                tokens(shown).font(.caption).foregroundStyle(Palette.secondary)
            }
            UsageChart(month: result.month, days: result.days, picked: $picked)
                .padding(.top, 14)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentTransition(.numericText())
        .animation(.snappy(duration: 0.2), value: picked)
    }

    private func dayRow(_ day: FishPocketUsageDay) -> some View {
        let on = picked == day.day
        return Button {
            Haptics.select()
            picked = on ? nil : day.day
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if month == .current && day.day == today {
                            Text("\(dayTitle(day.day)) · 今天")
                        } else {
                            Text(dayTitle(day.day))
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    tokens(day.usage).font(.caption).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 8)
                Text(day.usage.credits, format: .number)
                    .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(on ? Palette.spot.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("\(day.usage.credits) 积分"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Input, cache hits and output side by side: the first two don't overlap, so the three add
    /// up to everything the model read and wrote.
    private func tokens(_ usage: FishPocketUsage) -> Text {
        let compact = IntegerFormatStyle<Int>.number.notation(.compactName)
        let output = usage.outputTokens.formatted(compact)
        let line: String
        if let hit = usage.cacheHitInputTokens {
            let input = max(0, usage.inputTokens - hit).formatted(compact)
            let hits = hit.formatted(compact)
            if usage.inputTokens > 0 {
                // The share of all input that hit the cache, to the nearest percent, but never 100%
                // while some input missed.
                var percent = (Double(min(hit, usage.inputTokens)) * 100 / Double(usage.inputTokens)).rounded()
                if hit < usage.inputTokens { percent = min(percent, 99) }
                let rate = (percent / 100).formatted(.percent.precision(.fractionLength(0)))
                line = String(localized: "输入 \(input) · 缓存命中 \(hits)（\(rate)） · 输出 \(output) Token · \(usage.requests) 次")
            } else {
                // Nothing read (a day of voice only): no rate to give.
                line = String(localized: "输入 \(input) · 缓存命中 \(hits) · 输出 \(output) Token · \(usage.requests) 次")
            }
        } else {
            line = String(localized: "输入 \(usage.inputTokens.formatted(compact)) · 输出 \(output) Token · \(usage.requests) 次")
        }
        return Text(Self.wrappingAtSeparators(line))
    }

    /// Lets the line wrap only between its " · " parts, so a number never lands on another line
    /// than its label ("6.1" and "万", "·" and "12 次" ended up apart on narrow phones).
    static func wrappingAtSeparators(_ line: String) -> String {
        guard let separator = [" · ", "・"].first(where: line.contains) else { return line }
        return line.components(separatedBy: separator).map { part in
            // Word joiners between the characters, no-break spaces for the spaces.
            part.map { $0 == " " ? "\u{00A0}" : String($0) }.joined(separator: "\u{2060}")
        }
        // The dot stays at the end of the line it follows, never starts the next.
        .joined(separator: separator.hasPrefix(" ") ? "\u{00A0}" + separator.dropFirst() : separator)
    }

    // MARK: History

    @ViewBuilder
    private func history(_ records: FishPocketRecords) -> some View {
        switch records.history {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 160)
                .cardSurface()
        case .failed:
            retry { await records.loadHistory() }
        case .loaded(let entries):
            VStack(alignment: .leading, spacing: 2) {
                Text("累计到账").font(.footnote.weight(.medium)).foregroundStyle(Palette.secondary)
                amount(records.historyTotal ?? entries.reduce(0) { $0 + $1.credits })
                Text(entries.contains { $0.credits < 0 } ? "已扣除退款 · 购买的积分不会过期" : "购买的积分不会过期")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            if entries.isEmpty {
                empty(title: "还没有充值记录", detail: "购买额度包后，到账记录会显示在这里。")
            } else {
                section("充值记录")
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 16) }
                        entryRow(entry)
                            .onAppear {
                                if index == entries.count - 1 { Task { await records.loadMoreHistory() } }
                            }
                    }
                    if records.loadingMore {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 50)
                    }
                }
                .cardSurface()
                footnote("付款收据在「设置」里查看：轻点顶部的 Apple 账户，再到「媒体与购买项目」里的购买记录。")
            }
        }
    }

    private func entryRow(_ entry: FishPocketCreditEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entryTitle(entry.kind))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Text(entry.at, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(signed(entry.credits))
                    .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(entry.credits < 0 ? Palette.secondary : Palette.ink)
                Text(entry.credits < 0 ? "已扣回" : "已到账")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func entryTitle(_ kind: FishPocketCreditEntry.Kind) -> LocalizedStringKey {
        switch kind {
        case .purchase: "App Store 购买"
        case .refund: "App Store 退款"
        case .admin: "Fish Pocket 发放"
        case .promotion: "活动赠送"
        case .invite: "邀请奖励"
        case .subscription: "订阅额度"
        }
    }

    private func signed(_ credits: Int) -> String {
        (credits < 0 ? "−" : "+") + abs(credits).formatted(.number)
    }

    // MARK: Pieces

    private func amount(_ credits: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(credits, format: .number)
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("积分")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func section(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, 10)
    }

    private func empty(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 20)
    }

    private func retry(_ action: @escaping () async -> Void) -> some View {
        Button("暂时无法获取，轻点重试") { Task { await action() } }
            .font(.subheadline)
            .foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .cardSurface()
    }

    // MARK: Dates (Beijing)

    private var today: Int { FishPocketMonth.calendar.component(.day, from: Date()) }

    private func date(_ day: Int) -> Date {
        FishPocketMonth.calendar.date(from: DateComponents(year: month.year, month: month.month, day: day, hour: 12)) ?? Date()
    }

    private func dayTitle(_ day: Int) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted).month(.abbreviated).day()
        style.timeZone = FishPocketMonth.calendar.timeZone
        return date(day).formatted(style)
    }

    private func monthTitle(_ month: FishPocketMonth) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted).year().month(.wide)
        style.timeZone = FishPocketMonth.calendar.timeZone
        let date = FishPocketMonth.calendar.date(from: DateComponents(year: month.year, month: month.month, day: 15)) ?? Date()
        return date.formatted(style)
    }
}

private extension Optional where Wrapped == FishPocketRecords.Load<FishPocketUsageMonth> {
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

/// One bar per day of the month, tall by the credits spent; days without spending are a
/// faint stub. A tap picks a day (or lets go of it).
private struct UsageChart: View {
    let month: FishPocketMonth
    let days: [FishPocketUsageDay]
    @Binding var picked: Int?

    var body: some View {
        let count = month.days
        let byDay = Dictionary(days.map { ($0.day, $0.usage.credits) }, uniquingKeysWith: +)
        let top = max(1, byDay.values.max() ?? 1)
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(1...count, id: \.self) { day in
                    let credits = byDay[day] ?? 0
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 1, bottomTrailingRadius: 1, topTrailingRadius: 3)
                            .fill(color(day: day, credits: credits))
                            .frame(height: credits > 0 ? max(4, CGFloat(credits) / CGFloat(top) * 120) : 2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard credits > 0 else { picked = nil; return }
                        Haptics.select()
                        picked = picked == day ? nil : day
                    }
                }
            }
            .frame(height: 120)
            HStack {
                Text("\(1)日")
                Spacer()
                Text("\((count + 1) / 2)日")
                Spacer()
                Text("\(count)日")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Palette.faint)
        }
        .animation(.snappy(duration: 0.2), value: picked)
        // The list below says the same per day, readably; the bars are for the eye.
        .accessibilityHidden(true)
    }

    private func color(day: Int, credits: Int) -> Color {
        guard credits > 0 else { return Palette.stroke }
        if picked == day { return Palette.spot }
        return picked == nil ? Palette.ink : Palette.ink.opacity(0.3)
    }
}
