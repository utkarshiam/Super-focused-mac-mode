import Foundation

struct Recurrence: Codable, Hashable, Sendable {
    enum Frequency: String, Codable, CaseIterable, Identifiable, Sendable {
        case daily, weekly, monthly, yearly
        var id: String { rawValue }
        var unit: String {
            switch self {
            case .daily: "day"
            case .weekly: "week"
            case .monthly: "month"
            case .yearly: "year"
            }
        }
    }

    var frequency: Frequency
    var interval = 1
    /// Calendar weekday numbers (1 = Sunday … 7 = Saturday). Only used for weekly rules.
    var weekdays: [Int] = []

    init(frequency: Frequency, interval: Int = 1, weekdays: [Int] = []) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays.sorted()
    }

    enum CodingKeys: String, CodingKey { case frequency, interval, weekdays }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = c.value(.frequency, default: .daily)
        interval = max(1, c.value(.interval, default: 1))
        weekdays = c.value(.weekdays, default: [])
    }

    static let daily = Recurrence(frequency: .daily)
    static let weekdaysOnly = Recurrence(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])
    static let weekly = Recurrence(frequency: .weekly)
    static let biweekly = Recurrence(frequency: .weekly, interval: 2)
    static let monthly = Recurrence(frequency: .monthly)
    static let yearly = Recurrence(frequency: .yearly)

    /// One step forward from `date`.
    func advance(_ date: Date, calendar: Calendar = .current) -> Date {
        switch frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: interval, to: date)!
        case .weekly:
            guard !weekdays.isEmpty else {
                return calendar.date(byAdding: .weekOfYear, value: interval, to: date)!
            }
            var day = date
            for _ in 0..<8 {
                day = calendar.date(byAdding: .day, value: 1, to: day)!
                guard weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
                if interval > 1, !calendar.isDate(day, equalTo: date, toGranularity: .weekOfYear) {
                    // First matching day of the following week — skip the weeks in between.
                    return calendar.date(byAdding: .weekOfYear, value: interval - 1, to: day)!
                }
                return day
            }
            return calendar.date(byAdding: .weekOfYear, value: interval, to: date)!
        case .monthly:
            return calendar.date(byAdding: .month, value: interval, to: date)!
        case .yearly:
            return calendar.date(byAdding: .year, value: interval, to: date)!
        }
    }

    /// The next occurrence after completing an instance due at `due`.
    /// Skips occurrences that are already in the past so a late completion doesn't leave a backlog.
    func nextOccurrence(after due: Date, hasTime: Bool, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let floor = hasTime ? now : calendar.startOfDay(for: now)
        var next = advance(due, calendar: calendar)
        var guardCount = 0
        while next < floor && guardCount < 2000 {
            next = advance(next, calendar: calendar)
            guardCount += 1
        }
        return next
    }

    /// First date on or after `date` that matches the rule (used when a repeat is set without a deadline).
    func firstOccurrence(onOrAfter date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        if frequency == .weekly, !weekdays.isEmpty, !weekdays.contains(calendar.component(.weekday, from: start)) {
            let probe = Recurrence(frequency: .weekly, weekdays: weekdays)
            return probe.advance(start, calendar: calendar)
        }
        return start
    }

    var summary: String {
        if self == .weekdaysOnly { return "Every weekday" }
        let unit = frequency.unit
        var text = interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)s"
        if frequency == .weekly, !weekdays.isEmpty {
            let symbols = Calendar.current.shortWeekdaySymbols
            text += " on " + weekdays.map { symbols[($0 - 1) % 7] }.joined(separator: ", ")
        }
        return text
    }
}
