import Foundation

enum Fmt {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    private static let longDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f
    }()

    private static let dayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func time(_ d: Date) -> String { timeFormatter.string(from: d) }

    /// Whether this locale shows 12-hour times.
    static let uses12Hour: Bool = (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")

    private static let clockFormatter: DateFormatter = {
        // A fixed pattern: localized templates add the AM/PM marker back in.
        let f = DateFormatter()
        f.dateFormat = uses12Hour ? "h:mm" : "HH:mm"
        return f
    }()

    /// "11:00" and "AM" separately, so big labels can set the period smaller.
    static func timeParts(_ d: Date) -> (clock: String, period: String?) {
        guard uses12Hour else { return (clockFormatter.string(from: d), nil) }
        let hour = Calendar.current.component(.hour, from: d)
        let symbols = (timeFormatter.amSymbol ?? "AM", timeFormatter.pmSymbol ?? "PM")
        return (clockFormatter.string(from: d), (hour < 12 ? symbols.0 : symbols.1).uppercased())
    }

    /// "5 PM" (12-hour) or "17" (24-hour), for hour pickers.
    static func hourLabel(_ h: Int) -> String {
        guard uses12Hour else { return String(format: "%02d", h) }
        return "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")"
    }

    /// "11a", "3:30p" (12-hour) or "11:00", "15:30" — for tight spaces like month cells.
    static func compactTime(_ d: Date) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        guard uses12Hour else { return String(format: "%02d:%02d", h, m) }
        let h12 = h % 12 == 0 ? 12 : h % 12
        let suffix = h < 12 ? "a" : "p"
        return m == 0 ? "\(h12)\(suffix)" : String(format: "%d:%02d%@", h12, m, suffix)
    }
    static func longDay(_ d: Date) -> String { longDayFormatter.string(from: d) }
    static func dayKey(_ d: Date) -> String { dayKeyFormatter.string(from: d) }

    /// "Today", "Tomorrow", "Yesterday", weekday names within a week, otherwise a short date.
    static func relativeDay(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return "Today" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: d)).day ?? 0
        switch days {
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6:
            return weekdayFormatter.string(from: d)
        default:
            return calendar.isDate(d, equalTo: now, toGranularity: .year) ? dayFormatter.string(from: d) : dayYearFormatter.string(from: d)
        }
    }

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    private static let weekdayShortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    /// Compact day for big labels: "Today", "Tomorrow", "Yesterday", "Wed" (this week), else "9 Oct".
    static func shortDay(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return "Today" }
        let days = calendar.daysBetween(now, d)
        switch days {
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return weekdayShortFormatter.string(from: d)
        default: return shortDayFormatter.string(from: d)
        }
    }

    static func weekdayShort(_ d: Date) -> String { weekdayShortFormatter.string(from: d) }

    private static let absoluteDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    private static let absoluteDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
        return f
    }()

    /// Always the real date, never "Today"/"Tomorrow": "Mon 5 Oct" (year added when it isn't this year).
    static func absoluteDay(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(d, equalTo: now, toGranularity: .year) ? absoluteDayFormatter.string(from: d) : absoluteDayYearFormatter.string(from: d)
    }
    static func dayMonth(_ d: Date) -> String { shortDayFormatter.string(from: d) }

    /// "Mon 5 Oct · 3:00 pm", or just the day. Real dates everywhere, never "Today"/"Tomorrow".
    static func due(_ d: Date, hasTime: Bool, now: Date = Date()) -> String {
        let day = absoluteDay(d, now: now)
        return hasTime ? "\(day) · \(time(d))" : day
    }

    static func dateTime(_ d: Date) -> String { due(d, hasTime: true) }

    /// 90 -> "1h 30m", 45 -> "45m", 120 -> "2h"
    static func duration(minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m)m" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }

    static func duration(seconds: Int) -> String { duration(minutes: Int((Double(seconds) / 60).rounded())) }

    /// "24:13" or "1:02:07"
    static func clock(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

extension Calendar {
    func endOfDay(for date: Date) -> Date {
        self.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay(for: date))!
    }

    func daysBetween(_ a: Date, _ b: Date) -> Int {
        dateComponents([.day], from: startOfDay(for: a), to: startOfDay(for: b)).day ?? 0
    }
}

/// Deterministic string hash (Swift's `hashValue` changes on every launch).
func stableHash(_ s: String) -> String {
    var h: UInt64 = 5381
    for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
    return String(h, radix: 36)
}
