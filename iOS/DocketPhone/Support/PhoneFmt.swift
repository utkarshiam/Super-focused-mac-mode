import Foundation
import MemoryKit

/// Dates and durations the Docket way: real dates everywhere ("Mon 5 Oct · 10:00"), never
/// "Today"/"Tomorrow" as labels. Days come from `MemoryDates` so phone and Mac read the same.
enum PhoneFmt {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// "10:00" (or "10:00 AM" in 12-hour locales).
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// "Mon 5 Oct", or "5 Oct 2025" in another year.
    static func day(_ date: Date, now: Date = Date()) -> String { MemoryDates.label(date, now: now) }

    /// "Mon 5 Oct · 10:00".
    static func dayTime(_ date: Date, now: Date = Date()) -> String { "\(day(date, now: now)) · \(time(date))" }

    /// A due date: "Mon 5 Oct · 10:00" with a time, "Mon 5 Oct" without.
    static func due(_ date: Date, hasTime: Bool, now: Date = Date()) -> String {
        hasTime ? dayTime(date, now: now) : day(date, now: now)
    }

    /// 90 → "1h 30m", 45 → "45m", 120 → "2h".
    static func duration(minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m)m" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }

    /// A recording length: "0:07", "12:40".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "3 waiting to sync" style counts.
    static func count(_ n: Int, _ word: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? word : (plural ?? word + "s"))"
    }

    /// File-name-safe stamp: "2026-10-09 10.42.05".
    static func fileStamp(_ date: Date = Date()) -> String { stampFormatter.string(from: date) }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

/// Recognises a capture that is a link: exactly one web address in the text. The rest of the text,
/// if any, becomes the link's note.
enum LinkDetector {
    struct Match: Equatable {
        var url: String
        var note: String
    }

    static func match(_ text: String) -> Match? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let ns = trimmed as NSString
        let found = detector.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            .filter { result in
                guard let url = result.url, let scheme = url.scheme?.lowercased() else { return false }
                return scheme == "http" || scheme == "https"
            }
        guard found.count == 1, let result = found.first, let url = result.url else { return nil }
        let note = ns.replacingCharacters(in: result.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Match(url: url.absoluteString, note: note)
    }

    /// "example.com" for a URL string.
    static func host(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
