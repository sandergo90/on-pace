import Foundation

enum UsageFormat {
    static let locale = Locale(identifier: "en_US")

    static func euro(_ amount: Double) -> String {
        "≈ " + amount.formatted(.currency(code: "EUR").locale(.current))
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
    }

    static func lastUpdateCheck(
        _ date: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let date else { return "Not checked yet" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("HHmm")
            return "Last checked today at \(formatter.string(from: date))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.setLocalizedDateFormatFromTemplate("HHmm")
            return "Last checked yesterday at \(formatter.string(from: date))"
        }
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return "Last checked \(formatter.string(from: date))"
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
    }

    static func pacePercent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
    }

    static func paceMarker(_ fraction: Double) -> String {
        String.localizedStringWithFormat(String(localized: "pace.marker"), pacePercent(fraction))
    }

    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}
