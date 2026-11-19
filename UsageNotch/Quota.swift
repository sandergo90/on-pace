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

    func elapsedFraction(at date: Date) -> Double? {
        guard let resetsAt, let durationMinutes, durationMinutes > 0 else { return nil }
        let duration = Double(durationMinutes) * 60
        let remaining = resetsAt.timeIntervalSince(date)
        guard remaining > 0, remaining <= duration else { return nil }
        return (duration - remaining) / duration
    }

    func pace(sampledAt: Date, now: Date) -> QuotaPace? {
        guard elapsedFraction(at: now) != nil, let elapsed = elapsedFraction(at: sampledAt),
              let durationMinutes else { return nil }
        if level == .reached { return .reached }
        guard elapsed > 0 else { return nil }
        // The sample's usage and elapsed time must describe the same instant.
        if fractionUsed > elapsed {
            let elapsedSeconds = Double(durationMinutes) * 60 * elapsed
            let untilLimit = elapsedSeconds * (1 - fractionUsed) / fractionUsed
            return .limitAt(sampledAt.addingTimeInterval(untilLimit))
        }
        return .remaining(1 - fractionUsed / elapsed)
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

enum QuotaPace: Equatable {
    case remaining(Double), limitAt(Date), reached

    func title(at date: Date) -> String {
        switch self {
        case .remaining(let fraction):
            String.localizedStringWithFormat(String(localized: "pace.remaining"), UsageFormat.pacePercent(fraction))
        case .limitAt(let limit):
            String.localizedStringWithFormat(
                String(localized: "pace.limitAt"),
                Calendar.current.isDate(limit, inSameDayAs: date)
                    ? UsageFormat.time(limit) : "\(UsageFormat.weekday(limit)) \(UsageFormat.time(limit))"
            )
        case .reached:
            String(localized: "pace.reached")
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
        otherLimits.first { $0.durationMinutes == 10_080 && ["week", "primary", "secondary"].contains($0.id) }
            ?? session
    }

    var detailLimits: [QuotaWindow] {
        let primaryID = compactQuota?.id
        return ((session.map { [$0] } ?? []) + otherLimits).filter { $0.id != primaryID }
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
