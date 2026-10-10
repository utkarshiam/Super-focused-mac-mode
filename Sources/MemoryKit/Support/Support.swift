import Foundation

// MARK: - Tolerant decoding

/// Every MemoryKit model decodes files written by older (or newer) versions of either app:
/// a missing or unreadable key falls back to its default instead of failing the whole load.
/// Internal on purpose, so it never clashes with the app's own helper of the same shape.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
    }
}

// MARK: - JSON coding

/// The encoder and decoder every MemoryKit file uses: pretty-printed with sorted keys (diff-friendly),
/// ISO 8601 dates. Decoding also accepts fractional seconds and epoch numbers (seconds or
/// milliseconds), so files from ENGRAM or a hand edit still load.
public enum MemoryCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Same as `encoder` without the whitespace, for large files nobody reads by hand (the phone snapshot).
    public static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let number = try? c.decode(Double.self) { return date(epoch: number) }
            let text = try c.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a date: \(text)")
        }
        return d
    }()

    /// Epoch seconds, or milliseconds when the number is too big to be seconds (ENGRAM stores ms).
    static func date(epoch: Double) -> Date {
        Date(timeIntervalSince1970: epoch > 100_000_000_000 ? epoch / 1000 : epoch)
    }

    /// ISO 8601 with or without fractional seconds, or a plain "yyyy-MM-dd" day (local midnight).
    static func parseDate(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = isoPlain.date(from: s) ?? isoFractional.date(from: s) { return d }
        if s.count == 10, let d = MemoryDates.dayParser.date(from: s) { return d }
        return nil
    }

    private static let isoPlain: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Dates

/// Real dates, the way Docket writes them everywhere: "Mon 5 Oct", or "5 Oct 2025" for another year.
/// "Today"/"Tomorrow" are never labels. The Mac app has its own `Fmt`; this is for the iPhone app and
/// for prompts (which always carry the year so the model can't misplace a date).
public enum MemoryDates {
    /// "Mon 5 Oct" in the current year, "5 Oct 2025" otherwise, localized like the Mac app's `Fmt`.
    public static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return dayFormatter.string(from: date)
        }
        return dayYearFormatter.string(from: date)
    }

    /// "Mon 5 Oct 2026": unambiguous and fixed English, for prompts sent to Gemini.
    public static func prompt(_ date: Date) -> String { promptFormatter.string(from: date) }

    /// "2026-10-05" in the user's time zone: the shape Gemini is asked to return dates in.
    public static func dayKey(_ date: Date) -> String { dayParser.string(from: date) }

    /// Parses "2026-10-05" (local midnight). Nil for anything else, including "".
    public static func day(from key: String) -> Date? {
        let s = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count == 10 else { return nil }
        return dayParser.date(from: s)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    private static let dayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()

    private static let promptFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Text

enum TextFold {
    /// Case- and diacritic-insensitive form used for matching ("Café" → "cafe").
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// Folded words (letters and digits), in order.
    static func words(_ s: String) -> [String] {
        fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Words too common to say anything about what a text is about.
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from", "as",
        "is", "are", "was", "were", "be", "been", "it", "its", "this", "that", "these", "those", "i", "me", "my",
        "we", "our", "you", "your", "he", "she", "they", "them", "their", "his", "her", "what", "which", "who",
        "when", "where", "why", "how", "did", "do", "does", "done", "about", "any", "all", "can", "could",
        "should", "would", "will", "just", "so", "not", "no", "yes", "if", "then", "than", "there", "here",
        "have", "has", "had", "into", "out", "up", "down", "over", "also", "some", "more", "most", "very",
        "tell", "said", "say", "says", "get", "got", "re", "fwd", "fw",
    ]

    /// Trims and caps text at `limit` characters, ending with "…" when it was cut.
    static func cap(_ s: String, _ limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Collapses runs of whitespace, keeping paragraph breaks.
    static func tidy(_ s: String) -> String {
        let lines = s.components(separatedBy: .newlines).map {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ")
        }
        var out: [String] = []
        var blank = false
        for line in lines {
            if line.isEmpty {
                if !blank, !out.isEmpty { out.append("") }
                blank = true
            } else {
                out.append(line)
                blank = false
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unique, trimmed, non-empty names, first spelling wins, compared ignoring case and accents.
    static func uniqueNames(_ names: [String], limit: Int = 30) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#@")))
            guard !name.isEmpty, name.count <= 80, seen.insert(fold(name)).inserted else { continue }
            out.append(name)
            if out.count == limit { break }
        }
        return out
    }
}
