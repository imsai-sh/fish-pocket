import Foundation
import Observation

/// One month in Beijing time, which is what the Fish Pocket service counts days in.
struct FishPocketMonth: Hashable, Comparable {
    let year: Int
    let month: Int

    /// The calendar the service counts days in.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }()

    static var current: FishPocketMonth {
        let parts = calendar.dateComponents([.year, .month], from: Date())
        return FishPocketMonth(year: parts.year ?? 2026, month: parts.month ?? 1)
    }

    /// "2026-11"; nil for anything else.
    init?(_ text: String?) {
        guard let parts = text?.split(separator: "-"), parts.count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        self.init(year: year, month: month)
    }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    var text: String { String(format: "%04d-%02d", year, month) }
    var previous: FishPocketMonth { month == 1 ? .init(year: year - 1, month: 12) : .init(year: year, month: month - 1) }
    var next: FishPocketMonth { month == 12 ? .init(year: year + 1, month: 1) : .init(year: year, month: month + 1) }

    var days: Int {
        let start = Self.calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        return Self.calendar.range(of: .day, in: .month, for: start)?.count ?? 30
    }

    static func < (a: Self, b: Self) -> Bool { (a.year, a.month) < (b.year, b.month) }
}

/// What one day (or a whole month) of conversations on Fish Pocket credits cost.
struct FishPocketUsage: Equatable {
    var credits = 0
    /// All input tokens, cache hits included.
    var inputTokens = 0
    /// The part of `inputTokens` the model served from its prompt cache, billed far cheaper.
    /// Nil from a service too old to report it.
    var cacheHitInputTokens: Int?
    var outputTokens = 0
    var requests = 0

    init() {}

    init(_ json: JSON) {
        credits = json["credits"].int ?? 0
        inputTokens = json["inputTokens"].int ?? 0
        cacheHitInputTokens = json["cacheHitInputTokens"].int
        outputTokens = json["outputTokens"].int ?? 0
        requests = json["requests"].int ?? 0
    }
}

struct FishPocketUsageDay: Identifiable, Equatable {
    /// Day of the month, 1-based.
    let day: Int
    let usage: FishPocketUsage
    var id: Int { day }
}

/// `GET /v1/usage`: one month, the days with spending only.
struct FishPocketUsageMonth: Equatable {
    let month: FishPocketMonth
    /// The month of the account's first ledger entry: the earliest one worth showing.
    let since: FishPocketMonth?
    let total: FishPocketUsage
    let days: [FishPocketUsageDay]

    init(_ json: JSON, asked: FishPocketMonth) {
        month = FishPocketMonth(json["month"].string) ?? asked
        since = FishPocketMonth(json["since"].string)
        total = FishPocketUsage(json["total"])
        days = json["days"].array.compactMap { item in
            // "2026-11-23"
            guard let day = item["date"].string?.split(separator: "-").last.flatMap({ Int($0) }) else { return nil }
            return FishPocketUsageDay(day: day, usage: FishPocketUsage(item))
        }
    }
}

/// One line of `GET /v1/credit-history`: credits added, or taken back by a refund.
struct FishPocketCreditEntry: Identifiable, Equatable {
    enum Kind: String { case purchase, subscription, promotion, admin, refund, invite }

    let id: String
    let kind: Kind
    let credits: Int
    let at: Date

    init?(_ json: JSON) {
        guard let id = json["id"].string, let credits = json["credits"].int, let at = json["at"].double else { return nil }
        self.id = id
        kind = json["kind"].string.flatMap(Kind.init) ?? (credits < 0 ? .refund : .admin)
        self.credits = credits
        self.at = Date(timeIntervalSince1970: at / 1000)
    }
}

/// The records page's data: usage month by month (kept once read), and the credit history a
/// page at a time. Lives as long as the page.
@MainActor
@Observable
final class FishPocketRecords {
    enum Load<Value> {
        case loading
        case failed
        case loaded(Value)
    }

    @ObservationIgnored private let account: FishPocketAccount

    private(set) var months: [FishPocketMonth: Load<FishPocketUsageMonth>] = [:]
    /// The earliest month with anything, once a month has said.
    private(set) var since: FishPocketMonth?

    private(set) var history: Load<[FishPocketCreditEntry]> = .loading
    /// Net credits of the whole history (purchases and grants less refunds).
    private(set) var historyTotal: Int?
    private(set) var loadingMore = false
    @ObservationIgnored private var historyCursor: String?
    var hasMoreHistory: Bool { historyCursor != nil }

    init(account: FishPocketAccount) {
        self.account = account
    }

    /// Read a month unless it is already read; `force` reads it again.
    func load(_ month: FishPocketMonth, force: Bool = false) async {
        switch months[month] {
        case .loaded: if !force { return }
        case .loading: break
        case .failed, nil: months[month] = .loading
        }
        do {
            let reply = try await account.read("v1/usage", query: [URLQueryItem(name: "month", value: month.text)])
            let result = FishPocketUsageMonth(reply, asked: month)
            months[month] = .loaded(result)
            since = result.since
        } catch {
            // Cancelled (the page went away, or its task restarted): the next run reads it again.
            // A month already on screen stays there when a refresh fails.
            guard !Task.isCancelled else { return }
            if case .loaded = months[month] {} else { months[month] = .failed }
        }
    }

    func loadHistory() async {
        if case .loaded = history {} else { history = .loading }
        do {
            let reply = try await account.read("v1/credit-history")
            history = .loaded(reply["entries"].array.compactMap(FishPocketCreditEntry.init))
            historyTotal = reply["total"].int
            historyCursor = reply["next"].string
        } catch {
            guard !Task.isCancelled else { return }
            if case .loaded = history {} else { history = .failed }
        }
    }

    func loadMoreHistory() async {
        guard let cursor = historyCursor, !loadingMore, case .loaded(let entries) = history else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let reply = try? await account.read("v1/credit-history", query: [URLQueryItem(name: "before", value: cursor)]) else { return }
        let more = reply["entries"].array.compactMap(FishPocketCreditEntry.init)
        let known = Set(entries.map(\.id))
        history = .loaded(entries + more.filter { !known.contains($0.id) })
        historyCursor = reply["next"].string
    }
}
