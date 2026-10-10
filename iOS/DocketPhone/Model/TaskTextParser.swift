import Foundation
import MemoryKit

/// Reads a task said or typed without a Gemini key: the date and time (NSDataDetector, plus "at 9"), and a
/// length said as "for 30 minutes" / "for half an hour". What's left is the title. The Mac's QuickParser
/// still runs on receipt when no date was found here.
enum TaskTextParser {
    struct Result: Equatable {
        var title: String
        var due: Date?
        var hasTime: Bool
        var minutes: Int?
        /// "remind me 15 minutes before" → 15, "remind me at the time" → 0.
        var reminderMinutes: Int?
        var isAlarm = false
    }

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Result {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var minutes: Int?
        let (reminder, alarm) = reminderAndAlarm(&rest)
        if let (range, value) = duration(in: rest) {
            minutes = value
            rest.replaceSubrange(range, with: " ")
        }
        var due: Date?
        var hasTime = false
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
           let date = match.date, let range = Range(match.range, in: rest) {
            let said = String(rest[range])
            hasTime = said.range(of: timePattern, options: [.regularExpression, .caseInsensitive]) != nil
            if hasTime {
                due = date
                // A time alone ("at 9:30") means its next occurrence.
                if date < now, said.range(of: dayPattern, options: [.regularExpression, .caseInsensitive]) == nil {
                    due = calendar.date(byAdding: .day, value: 1, to: date)
                }
            } else {
                due = calendar.startOfDay(for: date)
            }
            rest.replaceSubrange(withPreposition(range, in: rest), with: " ")
        } else if let (range, date) = relativeTime(in: rest, now: now) ?? bareTime(in: rest, now: now, calendar: calendar) {
            due = date
            hasTime = true
            rest.replaceSubrange(withPreposition(range, in: rest), with: " ")
        }
        return Result(title: cleanTitle(rest), due: due, hasTime: hasTime, minutes: minutes,
                      reminderMinutes: due == nil ? nil : reminder, isAlarm: due != nil && alarm)
    }

    /// The task as it would be sent: title, date, time and length; everything else left to the Mac.
    static func draft(_ text: String, now: Date = Date()) -> DebriefTask {
        let r = parse(text, now: now)
        let title = r.title.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : r.title
        return DebriefTask(title: title, dueDate: r.due, dueHasTime: r.due != nil && r.hasTime, estimateMinutes: r.minutes,
                           reminderMinutes: r.reminderMinutes, isAlarm: r.isAlarm)
    }

    // MARK: Pieces

    private static let timePattern = #"\d{1,2}[:.]\d{2}|\d\s*(a\.?m\.?|p\.?m\.?)\b|\b(noon|midnight|morning|afternoon|evening|tonight|night|o'?clock)\b|\bat\s+\d"#
    private static let dayPattern = #"\b(today|tomorrow|tonight|mon|tue|wed|thu|fri|sat|sun|next|this|week|month|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\d{1,2}(st|nd|rd|th)\b|\d{1,2}/\d{1,2}"#

    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "ten": 10, "fifteen": 15,
        "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45, "forty five": 45, "ninety": 90,
    ]

    /// "for half an hour" → 30, "for 45 minutes" → 45, "for 1.5 hours" → 90, "for an hour and a half" → 90.
    static func duration(in text: String) -> (Range<String.Index>, Int)? {
        let lower = text.lowercased()
        let fixed: [(String, Int)] = [
            (#"\bfor\s+(an?|one)\s+hour\s+and\s+a\s+half\b"#, 90),
            (#"\bfor\s+half\s+an?\s+hour\b"#, 30),
            (#"\bfor\s+a\s+quarter\s+of\s+an\s+hour\b"#, 15),
        ]
        for (pattern, value) in fixed {
            if let r = lower.range(of: pattern, options: .regularExpression) { return (convert(r, from: lower, to: text), value) }
        }
        let pattern = #"\bfor\s+(\d+(?:\.\d+)?|an?|one|two|three|four|five|ten|fifteen|twenty|thirty|forty[- ]five|forty|ninety)\s*(hours?|hrs?|h|minutes?|mins?|m)\b"#
        guard let r = lower.range(of: pattern, options: .regularExpression),
              let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: lower, range: NSRange(r, in: lower)),
              let numberRange = Range(m.range(at: 1), in: lower), let unitRange = Range(m.range(at: 2), in: lower) else { return nil }
        let word = String(lower[numberRange])
        guard let number = Double(word) ?? numberWords[word] else { return nil }
        let unit = lower[unitRange]
        let minutes = unit.hasPrefix("h") ? number * 60 : number
        guard minutes >= 1, minutes <= 12 * 60 else { return nil }
        return (convert(r, from: lower, to: text), Int(minutes.rounded()))
    }

    /// "remind me 15 minutes before", "remind me at the time", "set an alarm": taken out of the text.
    private static func reminderAndAlarm(_ text: inout String) -> (Int?, Bool) {
        var reminder: Int?
        var alarm = false
        let lower = text.lowercased()
        let pattern = #"[,;]?\s*(and\s+)?(remind me|reminder|alert me|alarm)\s+(\d+|an?|one|two|five|ten|fifteen|twenty|thirty|half an?)\s*(hours?|hrs?|minutes?|mins?)\s+(before|earlier|ahead)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let whole = Range(m.range, in: lower), let n = Range(m.range(at: 3), in: lower), let u = Range(m.range(at: 4), in: lower) {
            let word = String(lower[n])
            let number = word.hasPrefix("half") ? 0.5 : (Double(word) ?? numberWords[word] ?? 0)
            reminder = Int((lower[u].hasPrefix("h") ? number * 60 : number).rounded())
            if lower[whole].contains("alarm") { alarm = true }
            text.replaceSubrange(convert(whole, from: lower, to: text), with: " ")
        } else if let r = lower.range(of: #"[,;]?\s*(and\s+)?remind me(?!\s+to\b)( at the time| then| on time)?(?=\W|$)"#, options: .regularExpression),
                  !lower[r].trimmingCharacters(in: .whitespaces).isEmpty {
            reminder = 0
            text.replaceSubrange(convert(r, from: lower, to: text), with: " ")
        }
        let lowered = text.lowercased()
        if let r = lowered.range(of: #"[,;]?\s*(and\s+)?(set\s+)?(an?\s+)?(alarm|wake me( up)?|don'?t let me miss it)(?=\W|$)"#, options: .regularExpression) {
            alarm = true
            if reminder == nil { reminder = 0 }
            text.replaceSubrange(convert(r, from: lowered, to: text), with: " ")
        }
        return (reminder, alarm)
    }

    /// "in 2 hours", "in 30 minutes", "in half an hour": that long from now.
    private static func relativeTime(in text: String, now: Date) -> (Range<String.Index>, Date)? {
        let lower = text.lowercased()
        let pattern = #"\bin\s+(half an?|\d+(?:\.\d+)?|an?|one|two|three|five|ten|fifteen|twenty|thirty|forty[- ]five)\s*(hours?|hrs?|minutes?|mins?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let whole = Range(m.range, in: lower), let n = Range(m.range(at: 1), in: lower), let u = Range(m.range(at: 2), in: lower) else { return nil }
        let word = String(lower[n])
        let number = word.hasPrefix("half") ? 0.5 : (Double(word) ?? numberWords[word] ?? 0)
        let minutes = lower[u].hasPrefix("h") ? number * 60 : number
        guard minutes > 0 else { return nil }
        let raw = now.addingTimeInterval(minutes * 60)
        // To the minute.
        let date = Date(timeIntervalSinceReferenceDate: (raw.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        return (convert(whole, from: lower, to: text), date)
    }

    /// The matched date plus a preposition right before it ("at 9:30", "by Friday").
    private static func withPreposition(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        let before = text[..<range.lowerBound]
        guard let r = before.range(of: #"\b(at|on|by|due|from|around|before)\s+$"#, options: [.regularExpression, .caseInsensitive]) else { return range }
        return r.lowerBound..<range.upperBound
    }

    /// "at 9", "at 7 pm" when NSDataDetector found nothing: the next time it's that o'clock (1–7 without am/pm
    /// is taken as the afternoon).
    private static func bareTime(in text: String, now: Date, calendar: Calendar) -> (Range<String.Index>, Date)? {
        let lower = text.lowercased()
        let pattern = #"\bat\s+(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?=\W|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let whole = Range(m.range, in: lower), let hourRange = Range(m.range(at: 1), in: lower),
              var hour = Int(lower[hourRange]), hour <= 23 else { return nil }
        let minute = Range(m.range(at: 2), in: lower).flatMap { Int(lower[$0]) } ?? 0
        let suffix = Range(m.range(at: 3), in: lower).map { String(lower[$0]) }
        if let suffix {
            if suffix.hasPrefix("p"), hour < 12 { hour += 12 }
            if suffix.hasPrefix("a"), hour == 12 { hour = 0 }
        } else if (1...7).contains(hour) {
            hour += 12
        }
        guard minute < 60, let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        let date = today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        return (convert(whole, from: lower, to: text), date)
    }

    private static func convert(_ range: Range<String.Index>, from lower: String, to text: String) -> Range<String.Index> {
        // lowercased() keeps the same characters for the scripts this sees; map by offsets to be safe.
        let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
        let length = lower.distance(from: range.lowerBound, to: range.upperBound)
        let s = text.index(text.startIndex, offsetBy: min(start, text.count))
        let e = text.index(s, offsetBy: min(length, text.distance(from: s, to: text.endIndex)))
        return s..<e
    }

    /// Drops the words left hanging after the date went ("… on", "by …"), lead-ins like "remind me to",
    /// and stray punctuation; capitalises the first letter.
    static func cleanTitle(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        let leadIns = #"^(please\s+)?(remind me to|i need to|i have to|i've got to|i must|add a task to|add a task|schedule a task to|schedule|add task|task:?)\s+"#
        t = t.replacingOccurrences(of: leadIns, with: "", options: [.regularExpression, .caseInsensitive])
        let hanging = #"(\s+|^)(at|on|by|for|from|this|next|due|before|in|around|and)[\s,.;:]*$"#
        var previous = ""
        while previous != t {
            previous = t
            t = t.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.;:-")))
            t = t.replacingOccurrences(of: hanging, with: "", options: [.regularExpression, .caseInsensitive])
        }
        guard let first = t.first else { return t }
        return first.uppercased() + t.dropFirst()
    }
}
