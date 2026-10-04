import Foundation

/// Result of parsing a quick-add line such as
/// "Review board deck tomorrow 4pm 45m !high #board @alarm15".
struct ParsedTask: Equatable {
    struct ReminderSpec: Equatable {
        var minutesBefore: Int
        var isAlarm: Bool
    }

    var title = ""
    var dueDate: Date?
    var dueHasTime = false
    var estimateMinutes: Int?
    var priority: Priority = .none
    var tags: [String] = []
    var listID: UUID?
    var recurrence: Recurrence?
    var reminders: [ReminderSpec] = []
}

/// Natural-language parser for quick add.
///
/// Supported syntax (all optional, any order):
/// - Dates: "tomorrow 4pm", "fri", "next tuesday at 10:30", "dec 3", "in 2 hours", "eod", "eow", "next week", "tonight"
/// - Estimate: "45m", "1h30m", "1.5h", "~2h", "for 30 min"
/// - Priority: "!" low, "!!" medium, "!!!" high, "!!!!" urgent, or "!high", "!urgent", …
/// - Tags / lists: "#board" (assigns the list called "Board" if one exists, otherwise a tag)
/// - Repeat: "every day", "every weekday", "every mon, thu", "every 2 weeks", "daily", "weekly", "monthly"
/// - Reminders: "@remind", "@remind30" (30 min before), "@alarm", "@alarm10", "@alarm1h"
struct QuickParser {
    var now = Date()
    var calendar = Calendar.current
    var lists: [TaskList] = []
    var workdayEndMinutes = 18 * 60

    private static let dayNamePattern = #"(?:mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)"#
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    func parse(_ raw: String) -> ParsedTask {
        var p = ParsedTask()
        var text = " " + raw.trimmingCharacters(in: .whitespacesAndNewlines) + " "

        // Shorthands people type fast.
        text = replace(#"\b(?:tmrw?|tmw|tmr)\b"#, in: text, with: "tomorrow")
        text = replace(#"\btdy\b"#, in: text, with: "today")

        parseTags(&text, into: &p)
        parsePriority(&text, into: &p)
        parseReminderTokens(&text, into: &p)
        parseRecurrence(&text, into: &p)
        parseRelativeOffset(&text, into: &p)
        parseKeywordDates(&text, into: &p)
        parseDuration(&text, into: &p)
        if p.dueDate == nil { parseDetectedDate(&text, into: &p) }

        if let rec = p.recurrence, p.dueDate == nil {
            p.dueDate = rec.firstOccurrence(onOrAfter: now, calendar: calendar)
            p.dueHasTime = false
        }

        p.title = cleanTitle(text, fallback: raw)
        return p
    }

    // MARK: Steps

    private func parseTags(_ text: inout String, into p: inout ParsedTask) {
        takeAll(#"(?<=\s)#(\p{L}[\p{L}\p{N}_\-/]*)"#, &text) { g in
            guard let tag = g[1] else { return false }
            let key = Self.normalize(tag)
            if p.listID == nil, let list = lists.first(where: { Self.normalize($0.name) == key }) {
                p.listID = list.id
            } else if !p.tags.contains(where: { $0.lowercased() == tag.lowercased() }) {
                p.tags.insert(tag, at: 0)
            }
            return true
        }
    }

    private func parsePriority(_ text: inout String, into p: inout ParsedTask) {
        takeFirst(#"(?<=\s)!(urgent|high|hi|medium|med|low|lo|!{0,3})(?=\s)"#, &text) { g in
            switch (g[1] ?? "").lowercased() {
            case "", "low", "lo": p.priority = .low
            case "!", "medium", "med": p.priority = .medium
            case "!!", "high", "hi": p.priority = .high
            case "!!!", "urgent": p.priority = .urgent
            default: return false
            }
            return true
        }
    }

    private func parseReminderTokens(_ text: inout String, into p: inout ParsedTask) {
        takeAll(#"(?<=\s)(?:@|⏰)(alarm|remind|reminder|notify|alert)?(?:[-:]?(\d+)\s?(m|min|mins|h|hr|hrs|d)?)?(?=\s)"#, &text) { g in
            let kind = (g[1] ?? "alarm").lowercased()
            var minutes = Int(g[2] ?? "0") ?? 0
            switch (g[3] ?? "m").lowercased() {
            case "h", "hr", "hrs": minutes *= 60
            case "d": minutes *= 1440
            default: break
            }
            p.reminders.insert(.init(minutesBefore: minutes, isAlarm: kind == "alarm"), at: 0)
            return true
        }
    }

    private func parseRecurrence(_ text: inout String, into p: inout ParsedTask) {
        let day = Self.dayNamePattern
        let rules: [(String, Bool, ([String?]) -> Recurrence?)] = [
            (#"\b(?:every\s+(?:weekday|workday|business\s+day)|on\s+weekdays|weekdays)\b"#, true, { _ in .weekdaysOnly }),
            (#"\bevery\s+(\#(day)(?:\s*(?:,|and|&)\s*\#(day))*)\b"#, true, { g in
                let days = Self.weekdayNumbers(in: g[1] ?? "")
                return days.isEmpty ? nil : Recurrence(frequency: .weekly, weekdays: days)
            }),
            (#"\bevery\s+other\s+(day|week|month|year)\b"#, true, { g in
                Recurrence.Frequency(unit: g[1]).map { Recurrence(frequency: $0, interval: 2) }
            }),
            (#"\bevery\s+(\d+)\s+(day|week|month|year)s?\b"#, true, { g in
                Recurrence.Frequency(unit: g[2]).map { Recurrence(frequency: $0, interval: Int(g[1] ?? "1") ?? 1) }
            }),
            (#"\bevery\s+(day|week|month|year)\b"#, true, { g in
                Recurrence.Frequency(unit: g[1]).map { Recurrence(frequency: $0) }
            }),
            // Bare adjectives set the repeat but stay in the title: "Weekly investor update".
            (#"\b(daily|weekly|monthly|yearly|annually|annual)\b"#, false, { g in
                switch (g[1] ?? "").lowercased() {
                case "daily": .daily
                case "weekly": .weekly
                case "monthly": .monthly
                default: .yearly
                }
            }),
        ]
        for (pattern, remove, make) in rules {
            var found = false
            takeFirst(pattern, &text) { g in
                guard let r = make(g) else { return false }
                p.recurrence = r
                found = true
                return remove
            }
            if found { return }
        }
    }

    private func parseRelativeOffset(_ text: inout String, into p: inout ParsedTask) {
        takeFirst(#"\bin\s+(\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten|a\s+couple\s+of)\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w|months?)\b"#, &text) { g in
            let n = Self.number(g[1] ?? "1")
            let unit = (g[2] ?? "").lowercased()
            if unit.hasPrefix("m") && !unit.hasPrefix("mo") {
                p.dueDate = now.addingTimeInterval(Double(n) * 60)
                p.dueHasTime = true
            } else if unit.hasPrefix("h") {
                p.dueDate = now.addingTimeInterval(Double(n) * 3600)
                p.dueHasTime = true
            } else {
                let comp: Calendar.Component = unit.hasPrefix("d") ? .day : unit.hasPrefix("w") ? .weekOfYear : .month
                p.dueDate = calendar.startOfDay(for: calendar.date(byAdding: comp, value: n, to: now)!)
                p.dueHasTime = false
            }
            return true
        }
    }

    private func parseKeywordDates(_ text: inout String, into p: inout ParsedTask) {
        guard p.dueDate == nil else { return }
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today) // 1 = Sun

        let rules: [(String, () -> (Date, Bool))] = [
            (#"\b(?:by\s+)?(?:eod|end\s+of\s+(?:the\s+)?day)\b"#, {
                (calendar.date(byAdding: .minute, value: workdayEndMinutes, to: today)!, true)
            }),
            (#"\b(?:by\s+)?(?:eow|end\s+of\s+(?:the\s+)?week)\b"#, {
                let toFriday = (6 - weekday + 7) % 7
                return (calendar.date(byAdding: .day, value: toFriday, to: today)!, false)
            }),
            (#"\bnext\s+week\b"#, {
                let toMonday = (2 - weekday + 7) % 7
                return (calendar.date(byAdding: .day, value: toMonday == 0 ? 7 : toMonday, to: today)!, false)
            }),
            (#"\b(?:this\s+)?weekend\b"#, {
                let toSaturday = weekday == 1 ? 0 : (7 - weekday)
                return (calendar.date(byAdding: .day, value: toSaturday, to: today)!, false)
            }),
            (#"\bnext\s+month\b"#, {
                let start = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
                return (calendar.date(byAdding: .month, value: 1, to: start)!, false)
            }),
            (#"\b(?:by\s+)?(?:eom|end\s+of\s+(?:the\s+)?month)\b"#, {
                let start = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
                return (calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!, false)
            }),
        ]
        for (pattern, make) in rules {
            var found = false
            takeFirst(pattern, &text) { _ in
                let (date, hasTime) = make()
                p.dueDate = date
                p.dueHasTime = hasTime
                found = true
                return true
            }
            if found { return }
        }
    }

    private func parseDuration(_ text: inout String, into p: inout ParsedTask) {
        let hours = #"(?<![\w:.])(?:for\s+)?~?(\d+(?:[.,]\d+)?)\s?(?:h|hr|hrs|hour|hours)(?:\s?(\d{1,2})\s?(?:m|min|mins|minutes)?)?(?![\w])"#
        let minutes = #"(?<![\w:.])(?:for\s+)?~?(\d+)\s?(?:m|min|mins|minute|minutes)(?![\w])"#
        let words = #"\b(?:for\s+)?(half\s+an\s+hour|an\s+hour)\b"#

        var done = false
        takeFirst(hours, &text) { g in
            let h = Double((g[1] ?? "0").replacingOccurrences(of: ",", with: ".")) ?? 0
            let m = Int(g[2] ?? "0") ?? 0
            p.estimateMinutes = Int((h * 60).rounded()) + m
            done = true
            return true
        }
        if done { return }
        takeFirst(minutes, &text) { g in
            p.estimateMinutes = Int(g[1] ?? "0")
            done = true
            return true
        }
        if done { return }
        takeFirst(words, &text) { g in
            p.estimateMinutes = (g[1] ?? "").lowercased().hasPrefix("half") ? 30 : 60
            return true
        }
    }

    private func parseDetectedDate(_ text: inout String, into p: inout ParsedTask) {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        guard let match = Self.detector.matches(in: text, range: all).first(where: { $0.date != nil }),
              var date = match.date else { return }

        var range = match.range
        var matched = ns.substring(with: range)
        var impliesTime = false

        // The detector folds meal words into the date ("Dinner tonight"); keep them in the title.
        if let meal = try? NSRegularExpression(pattern: #"^(breakfast|brunch|lunch|dinner|supper)\b\s*"#, options: .caseInsensitive),
           let m = meal.firstMatch(in: matched, range: NSRange(location: 0, length: (matched as NSString).length)) {
            range.location += m.range.length
            range.length -= m.range.length
            matched = ns.substring(with: range)
            impliesTime = true
        }

        let timePattern = #"\d{1,2}(:\d{2})?\s*(a\.?m\.?|p\.?m\.?)|\b\d{1,2}[:.]\d{2}\b|\b(noon|midnight|tonight|morning|afternoon|evening|night)\b"#
        let hasTime = impliesTime || matched.range(of: timePattern, options: [.regularExpression, .caseInsensitive]) != nil

        if hasTime {
            // "3pm" typed at 4pm means tomorrow.
            let timeOnly = #"^\s*(at\s+)?(\d{1,2}([:.]\d{2})?\s*(a\.?m\.?|p\.?m\.?)?|noon|midnight)\s*$"#
            if matched.range(of: timeOnly, options: [.regularExpression, .caseInsensitive]) != nil, date < now.addingTimeInterval(-60) {
                date = calendar.date(byAdding: .day, value: 1, to: date)!
            }
            p.dueDate = date
            p.dueHasTime = true
        } else {
            p.dueDate = calendar.startOfDay(for: date)
            p.dueHasTime = false
        }

        var before = ns.substring(to: range.location)
        let after = ns.substring(from: range.location + range.length)
        before = replace(#"\s+(by|on|at|due|before|until|till)\s*$"#, in: before, with: " ")
        text = before + " " + after
    }

    // MARK: Helpers

    private func cleanTitle(_ text: String, fallback: String) -> String {
        var t = replace(#"\s+"#, in: text, with: " ").trimmingCharacters(in: .whitespaces)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
        if t.isEmpty {
            t = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return "New task" }
        }
        let chars = Array(t)
        if let first = chars.first, first.isLowercase, chars.count == 1 || !chars[1].isUppercase {
            t = first.uppercased() + t.dropFirst()
        }
        return t
    }

    private func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
    }

    /// Calls `body` with capture groups for every match (last to first); removes matches for which it returns true.
    private func takeAll(_ pattern: String, _ text: inout String, _ body: ([String?]) -> Bool) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
        var ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            if body(Self.groups(m, ns)) { ns = ns.replacingCharacters(in: m.range, with: " ") as NSString }
        }
        text = ns as String
    }

    private func takeFirst(_ pattern: String, _ text: inout String, _ body: ([String?]) -> Bool) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if body(Self.groups(m, ns)) {
                text = ns.replacingCharacters(in: m.range, with: " ")
                return
            }
        }
    }

    private static func groups(_ m: NSTextCheckingResult, _ ns: NSString) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func number(_ word: String) -> Int {
        if let n = Int(word) { return n }
        let w = word.lowercased()
        if w.hasPrefix("a couple") { return 2 }
        return ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10][w] ?? 1
    }

    static func weekdayNumbers(in text: String) -> [Int] {
        let map: [(String, Int)] = [("sun", 1), ("mon", 2), ("tue", 3), ("wed", 4), ("thu", 5), ("fri", 6), ("sat", 7)]
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        var result: [Int] = []
        for w in words {
            if let (_, n) = map.first(where: { w.hasPrefix($0.0) }), !result.contains(n) { result.append(n) }
        }
        return result.sorted()
    }
}

extension Recurrence.Frequency {
    init?(unit: String?) {
        switch (unit ?? "").lowercased() {
        case "day": self = .daily
        case "week": self = .weekly
        case "month": self = .monthly
        case "year": self = .yearly
        default: return nil
        }
    }
}
