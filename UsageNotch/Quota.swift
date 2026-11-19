import Foundation

enum Provider: CaseIterable, Identifiable, Sendable {
    case claude, codex

    var id: Self { self }
    var name: String { self == .claude ? "Claude" : "Codex" }
    var command: String { self == .claude ? "claude" : "codex" }
}

struct QuotaWindow: Identifiable, Sendable {
    let id: String
    let title: String
    let used: Double
    let resetsAt: Date?
    let durationMinutes: Int?

    init?(_ id: String, title: String, used: Double?, resetsAt: Date?, durationMinutes: Int? = nil) {
        guard let used, used.isFinite, used >= 0 else { return nil }
        self.id = id
        self.title = title
        self.used = used
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }

    var fractionUsed: Double { min(used / 100, 1) }

    func fillWidth(in width: Double, minimum: Double) -> Double {
        used == 0 ? 0 : min(width, max(minimum, width * fractionUsed))
    }

    var level: QuotaLevel {
        if used >= 100 { return .reached }
        if used >= 80 { return .warning }
        return .normal
    }

    func minutesUntilReset(from now: Date) -> Int? {
        resetsAt.map { Int(max(0, $0.timeIntervalSince(now) / 60).rounded(.up)) }
    }

    func compactReset(at now: Date) -> CompactQuotaReset? {
        switch durationMinutes {
        case 300: minutesUntilReset(from: now).map(CompactQuotaReset.countdown)
        case 10_080: resetsAt.map(CompactQuotaReset.weekly)
        default: nil
        }
    }

    func pace(at now: Date) -> QuotaPace? {
        guard let durationMinutes, durationMinutes > 0 else { return nil }
        if level == .reached { return .reached }
        guard let resetsAt, resetsAt > now else { return nil }
        let duration = Double(durationMinutes) * 60
        let elapsed = duration - resetsAt.timeIntervalSince(now)
        guard elapsed >= duration * 0.15 else { return nil }
        let projected = used * duration / elapsed
        if projected >= 100 {
            let predicted = now.addingTimeInterval((100 - used) * elapsed / used)
            let showWeekday = durationMinutes == 10_080 && !Calendar.current.isDate(predicted, inSameDayAs: now)
            return .limitAt(projected: projected, date: predicted, showWeekday: showWeekday)
        }
        return .projected(projected)
    }

    var percentage: String {
        "\(min(used, 100).rounded(.down).formatted(.number.precision(.fractionLength(0))))%"
    }

    var compactPeriod: String? {
        switch durationMinutes {
        case 300: "5h"
        case 10_080: "wk"
        default: nil
        }
    }
}

enum CompactQuotaReset {
    case countdown(Int)
    case weekly(Date)

    var text: String {
        switch self {
        case .countdown(let minutes): UsageFormat.duration(minutes)
        case .weekly(let date): "\(UsageFormat.weekday(date)) \(UsageFormat.time(date))"
        }
    }

    var spoken: String {
        switch self {
        case .countdown(let minutes):
            let hours = minutes / 60
            let remainder = minutes % 60
            let hourText = "\(hours) \(hours == 1 ? "hour" : "hours")"
            let minuteText = "\(remainder) \(remainder == 1 ? "minute" : "minutes")"
            let duration = hours == 0 ? minuteText : (remainder == 0 ? hourText : "\(hourText) \(minuteText)")
            return "resets in \(duration)"
        case .weekly(let date):
            let weekday = date.formatted(.dateTime.weekday(.wide).locale(UsageFormat.locale))
            return "resets \(weekday) \(UsageFormat.time(date))"
        }
    }
}

enum QuotaPace {
    case projected(Double)
    case limitAt(projected: Double, date: Date, showWeekday: Bool)
    case reached

    var projectedPercentage: Double? {
        switch self {
        case .projected(let percentage), .limitAt(let percentage, _, _): percentage
        case .reached: nil
        }
    }

    var projectedFraction: Double? {
        projectedPercentage.map { min($0, 100) / 100 }
    }

    var isEmphasized: Bool {
        projectedPercentage.map { $0 >= 75 } ?? true
    }

    var title: String {
        switch self {
        case .projected(let percentage):
            isEmphasized ? "On pace for ~\(Int(percentage.rounded()))% by reset" : "Well within limit"
        case .limitAt(_, let date, let showWeekday):
            "On pace to hit limit ~\(showWeekday ? UsageFormat.weekday(date) + " " : "")\(UsageFormat.time(date))"
        case .reached: "Limit reached"
        }
    }

    var accessibilitySuffix: String {
        switch self {
        case .projected(let percentage): ", on pace for about \(Int(percentage.rounded()))% by reset"
        case .limitAt: ", on pace to reach the limit before reset"
        case .reached: ""
        }
    }
}

enum QuotaLevel {
    case normal, warning, reached
}

struct UsageReading: Sendable {
    let session: QuotaWindow?
    let otherLimits: [QuotaWindow]
    let plan: String?
    let fetchedAt: Date

    init?(windows: [QuotaWindow], plan: String?, fetchedAt: Date = .now) {
        guard !windows.isEmpty else { return nil }
        let session = windows.first { $0.id != "cloud" && $0.durationMinutes == 300 }
        self.session = session
        self.otherLimits = windows.filter { $0.id != session?.id }
        self.plan = plan
        self.fetchedAt = fetchedAt
    }

    var compactQuota: QuotaWindow? {
        session ?? otherLimits.first { $0.id != "cloud" && $0.durationMinutes == 10_080 }
    }

    var detailLimits: [QuotaWindow] {
        otherLimits.filter { $0.id != compactQuota?.id }
    }

    var reportedLimitsDescription: String {
        let windows = (session.map { [$0] } ?? []) + otherLimits
        var labels: [String] = []
        if session != nil { labels.append("5-hour session") }
        let weekly = windows.filter { $0.durationMinutes == 10_080 || $0.title.localizedCaseInsensitiveContains("weekly") }
        if !weekly.isEmpty { labels.append(weekly.count == 1 ? "weekly limit" : "weekly limits") }
        labels += windows.filter { window in
            window.id != session?.id && !weekly.contains(where: { $0.id == window.id })
        }.map { $0.title.lowercased() }
        return labels.joined(separator: " and ")
    }

    func didResetCompactQuota(since previous: UsageReading) -> Bool {
        guard let oldWindow = previous.compactQuota,
              let newWindow = compactQuota,
              oldWindow.id == newWindow.id,
              oldWindow.durationMinutes == newWindow.durationMinutes,
              let oldReset = oldWindow.resetsAt,
              let newReset = newWindow.resetsAt else { return false }

        return fetchedAt > previous.fetchedAt && oldReset <= fetchedAt && newReset > fetchedAt
    }

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) >= 300
    }
}

enum UsageFailure: Error, Sendable {
    case commandMissing, signInRequired, noQuota, timedOut, unavailable

    func message(for provider: Provider) -> String {
        switch self {
        case .commandMissing: "Install the \(provider.name) CLI."
        case .signInRequired: "Sign in with \(provider.command) in Terminal."
        case .noQuota: "No subscription quota reported."
        case .timedOut: "\(provider.name) did not respond."
        case .unavailable: "Could not refresh quota."
        }
    }
}

enum UsageState {
    case loading
    case current(UsageReading)
    case unavailable(UsageFailure, previous: UsageReading?)

    var reading: UsageReading? {
        switch self {
        case .loading: nil
        case .current(let reading), .unavailable(_, .some(let reading)): reading
        case .unavailable(_, .none): nil
        }
    }

    var isDisconnected: Bool {
        switch self {
        case .unavailable(.commandMissing, nil), .unavailable(.signInRequired, _), .unavailable(.noQuota, _):
            true
        default:
            false
        }
    }
}
