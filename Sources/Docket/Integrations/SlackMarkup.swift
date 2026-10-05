import Foundation
import SwiftUI

/// Slack's mrkdwn, read once and shown two ways: rich text for the message pane (`SlackText.attributed`)
/// and plain words for thread previews and AI (`SlackText.readable`).
///
/// It follows Slack's own rules. *bold*, _italic_ and ~strike~ open after a space or punctuation and close
/// before one, never across lines ("snake_case" and "2*3*4" stay as they are). `code` and ``` blocks keep
/// their text as written. Links, people, channels and @here come from the <…> tokens. &amp; &lt; and &gt;
/// are the only escapes. A line starting with > is quoted (>>> quotes the rest of the message). Known
/// emoji :names: become emoji.
enum SlackMarkup {
    struct Style: OptionSet, Hashable {
        let rawValue: Int
        static let bold = Style(rawValue: 1 << 0)
        static let italic = Style(rawValue: 1 << 1)
        static let strike = Style(rawValue: 1 << 2)
        static let code = Style(rawValue: 1 << 3)
        /// @someone, #channel, @here.
        static let mention = Style(rawValue: 1 << 4)
    }

    enum Block: Hashable { case text, quote, code }

    /// A stretch of the message with one look.
    struct Run: Hashable {
        var text: String
        var style: Style = []
        /// Only http, https and mailto links: a message can't make Docket open anything else.
        var link: URL?
        var block: Block = .text
        /// Starts a quoted line: drawn as a bar, written as "> ".
        var isQuoteMark = false
    }

    /// The bar in front of a quoted line (a hairline, like quotes in notes).
    static let quoteBar = "▎ "

    static func runs(_ markup: String, names: [String: String]) -> [Run] {
        let reader = Reader(names: names)
        reader.read(markup)
        return reader.runs
    }

    /// For SwiftUI's Text: emphasis, code and links as inline presentation intents and link attributes,
    /// the few colours from the theme (quotes in ink2, struck text in ink3, code on fill).
    static func attributed(_ runs: [Run]) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.isQuoteMark ? quoteBar : run.text)
            var intent = InlinePresentationIntent()
            if run.style.contains(.bold) || run.style.contains(.mention) { intent.insert(.stronglyEmphasized) }
            if run.style.contains(.italic) { intent.insert(.emphasized) }
            if run.style.contains(.strike) { intent.insert(.strikethrough) }
            let isCode = run.style.contains(.code) || run.block == .code
            if isCode { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if isCode { piece.swiftUI.backgroundColor = Color.fill }
            if run.isQuoteMark {
                piece.swiftUI.foregroundColor = Color.hairStrong
            } else if run.style.contains(.strike) {
                piece.swiftUI.foregroundColor = Color.ink3
            } else if run.block == .quote {
                piece.swiftUI.foregroundColor = Color.ink2
            }
            if let link = run.link { piece.link = link }
            out.append(piece)
        }
        return out
    }

    static func readable(_ runs: [Run]) -> String {
        runs.map { $0.isQuoteMark ? "> " : $0.text }.joined()
    }

    // MARK: Inline rules

    fileprivate static let marks: [Character: Style] = ["*": .bold, "_": .italic, "~": .strike]
    /// How far a mark looks for its partner: Slack's formatting is for words and phrases, and the cap keeps a
    /// line full of stray asterisks quick.
    fileprivate static let maxSpan = 2_000

    /// Whether the mark at `i` can start formatting: after a space or punctuation (or the line's start),
    /// before a non-space.
    fileprivate static func opens(_ c: [Character], at i: Int, before limit: Int) -> Bool {
        guard i + 1 < limit else { return false }
        let mark = c[i], next = c[i + 1]
        if next.isWhitespace || next == mark { return false }
        if i > 0 {
            let prev = c[i - 1]
            if prev.isLetter || prev.isNumber || prev == mark { return false }
        }
        return true
    }

    /// Where the formatting opened at `i` closes: the same mark after a non-space and before a space,
    /// punctuation or the line's end. Code and <tokens> in between are skipped whole.
    fileprivate static func closer(in c: [Character], atoms: [Int?], after i: Int, before limit: Int) -> Int? {
        let mark = c[i]
        let end = min(limit, i + 1 + maxSpan)
        var j = i + 1
        while j < end {
            if let atomEnd = atoms[j] {
                j = atomEnd + 1
                continue
            }
            if c[j] == mark, j > i + 1 {
                let prev = c[j - 1]
                let next: Character? = j + 1 < c.count ? c[j + 1] : nil
                let nextJoins = next.map { $0.isLetter || $0.isNumber || $0 == mark } ?? false
                if !prev.isWhitespace, prev != mark, !nextJoins { return j }
            }
            j += 1
        }
        return nil
    }

    /// Where each `code` span and <token> on a line ends, by where it starts. Found in one pass from the
    /// left, so marks inside them never count.
    fileprivate static func atoms(in c: [Character]) -> [Int?] {
        let n = c.count
        var ends = [Int?](repeating: nil, count: n)
        // The next "`", ">" and "<" at or after each position (n when there's none).
        var nextTick = [Int](repeating: n, count: n + 1)
        var nextClose = [Int](repeating: n, count: n + 1)
        var nextOpen = [Int](repeating: n, count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            nextTick[i] = c[i] == "`" ? i : nextTick[i + 1]
            nextClose[i] = c[i] == ">" ? i : nextClose[i + 1]
            nextOpen[i] = c[i] == "<" ? i : nextOpen[i + 1]
        }
        var i = 0
        while i < n {
            if c[i] == "`" {
                let j = nextTick[i + 1]
                if j == i + 1 {
                    i += 2 // `` is just two backticks
                    continue
                }
                if j < n {
                    ends[i] = j
                    i = j + 1
                    continue
                }
            } else if c[i] == "<" {
                let j = nextClose[i + 1]
                if j < n, j > i + 1, nextOpen[i + 1] > j {
                    ends[i] = j
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return ends
    }

    /// <!date^1792000000^{date_short} at {time}|fallback>: in this Mac's time zone, as real dates
    /// ("Mon 5 Oct at 10:00 AM"), never "today".
    fileprivate static func date(_ parts: [String], fallback: String?) -> String {
        guard parts.count >= 3, let seconds = TimeInterval(parts[1]), seconds.isFinite, seconds > 0, seconds < 1e11 else {
            return fallback ?? ""
        }
        let date = Date(timeIntervalSince1970: seconds)
        let day = Fmt.absoluteDay(date)
        let replacements = [
            ("{date_num}", Fmt.dayKey(date)), ("{date}", day), ("{date_short}", day), ("{date_long}", day),
            ("{date_pretty}", day), ("{date_short_pretty}", day), ("{date_long_pretty}", day),
            ("{time}", Fmt.time(date)), ("{time_secs}", Fmt.time(date)), ("{ago}", Fmt.due(date, hasTime: true)),
        ]
        var text = SlackText.unescape(parts[2])
        for (token, value) in replacements { text = text.replacingOccurrences(of: token, with: value) }
        return text.isEmpty ? fallback ?? "" : text
    }

    fileprivate static func safeLink(_ address: String) -> URL? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
            return nil
        }
        return url
    }
}

// MARK: - Reading

private final class Reader {
    typealias Run = SlackMarkup.Run
    typealias Style = SlackMarkup.Style
    typealias Block = SlackMarkup.Block

    let names: [String: String]
    private(set) var runs: [Run] = []
    /// After a line starting with >>>, the rest of the message is quoted.
    private var quotingRest = false
    private var lastWasCode = false

    init(names: [String: String]) {
        self.names = names
    }

    func read(_ markup: String) {
        var pieces = markup.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "```")
        // Fences pair up in order: text, code, text… A last fence without a partner is just text.
        if pieces.count >= 2, pieces.count % 2 == 0 {
            let tail = pieces.removeLast()
            pieces[pieces.count - 1] += "```" + tail
        }
        for (index, piece) in pieces.enumerated() {
            if index % 2 == 1 { code(piece) } else { text(piece) }
        }
        trim()
    }

    /// A ``` block, on lines of its own.
    private func code(_ raw: String) {
        var body = Substring(raw)
        if body.hasPrefix("\n") { body = body.dropFirst() }
        if body.hasSuffix("\n") { body = body.dropLast() }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let last = runs.last, !last.text.hasSuffix("\n") {
            // Started mid-line ("See ```x = 1```"): the line ends here, without its trailing space.
            if !last.isQuoteMark, last.block != .code {
                var trimmed = last
                while trimmed.text.last == " " || trimmed.text.last == "\t" { trimmed.text.removeLast() }
                if trimmed.text.isEmpty { runs.removeLast() } else { runs[runs.count - 1] = trimmed }
            }
            runs.append(Run(text: "\n"))
        }
        runs.append(Run(text: literal(String(body)), block: .code))
        lastWasCode = true
    }

    private func text(_ raw: String) {
        var piece = Substring(raw)
        if lastWasCode, !piece.hasPrefix("\n") {
            // Ended mid-line ("``` above"): what follows starts a line of its own.
            while piece.first == " " || piece.first == "\t" { piece = piece.dropFirst() }
            if !piece.isEmpty, !piece.hasPrefix("\n") { runs.append(Run(text: "\n")) }
        }
        lastWasCode = false
        for (i, line) in piece.components(separatedBy: "\n").enumerated() {
            if i > 0 { runs.append(Run(text: "\n")) }
            self.line(line)
        }
    }

    private func line(_ raw: String) {
        var body = Substring(raw)
        var quoted = quotingRest
        // Slack escapes ">", so a quote arrives as "&gt;". Inside a >>> quote, a line's own mark goes too.
        if let marker = ["&gt;&gt;&gt;", ">>>"].first(where: { body.hasPrefix($0) }) {
            body = body.dropFirst(marker.count)
            quotingRest = true
            quoted = true
        } else if let marker = ["&gt;", ">"].first(where: { body.hasPrefix($0) }) {
            body = body.dropFirst(marker.count)
            quoted = true
        }
        if quoted {
            if body.hasPrefix(" ") { body = body.dropFirst() }
            runs.append(Run(text: "", block: .quote, isQuoteMark: true))
        }
        guard !body.isEmpty else { return }
        let chars = Array(body)
        parse(chars, atoms: SlackMarkup.atoms(in: chars), 0..<chars.count, style: [], block: quoted ? .quote : .text)
    }

    private func parse(_ c: [Character], atoms: [Int?], _ range: Range<Int>, style: Style, block: Block) {
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            runs.append(Run(text: SlackEmoji.replacingShortcodes(in: SlackText.unescape(pending)), style: style, block: block))
            pending = ""
        }
        var i = range.lowerBound
        while i < range.upperBound {
            let ch = c[i]
            if let end = atoms[i], end < range.upperBound {
                flush()
                let inner = String(c[(i + 1)..<end])
                if ch == "`" {
                    runs.append(Run(text: literal(inner), style: style.union(.code), block: block))
                } else {
                    token(inner, style: style, block: block)
                }
                i = end + 1
                continue
            }
            if let mark = SlackMarkup.marks[ch], SlackMarkup.opens(c, at: i, before: range.upperBound),
               let end = SlackMarkup.closer(in: c, atoms: atoms, after: i, before: range.upperBound) {
                flush()
                parse(c, atoms: atoms, (i + 1)..<end, style: style.union(mark), block: block)
                i = end + 1
                continue
            }
            pending.append(ch)
            i += 1
        }
        flush()
    }

    /// <@U…|name>, <#C…|name>, <!here>, <https://…|label>, <mailto:…>.
    private func token(_ inner: String, style: Style, block: Block) {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let target = parts[0]
        let label = parts.count > 1 && !parts[1].isEmpty ? SlackText.unescape(parts[1]) : nil
        switch target.first {
        case "@":
            let name = names[String(target.dropFirst())] ?? label.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 } ?? "someone"
            runs.append(Run(text: "@" + name, style: style.union(.mention), block: block))
        case "#":
            runs.append(Run(text: "#" + (label ?? names[String(target.dropFirst())] ?? "channel"), style: style.union(.mention), block: block))
        case "!":
            let command = target.dropFirst().split(separator: "^", omittingEmptySubsequences: false).map(String.init)
            switch command[0] {
            case "here", "channel", "everyone":
                runs.append(Run(text: "@" + command[0], style: style.union(.mention), block: block))
            case "subteam":
                let team = label.map { $0.hasPrefix("@") ? $0 : "@" + $0 } ?? "@team"
                runs.append(Run(text: team, style: style.union(.mention), block: block))
            case "date":
                let when = SlackMarkup.date(command, fallback: label)
                if !when.isEmpty { runs.append(Run(text: when, style: style, block: block)) }
            default:
                runs.append(Run(text: label ?? "@" + command[0], style: style, block: block))
            }
        default:
            let address = SlackText.unescape(target)
            let shown = label ?? (address.lowercased().hasPrefix("mailto:") ? String(address.dropFirst("mailto:".count)) : address)
            runs.append(Run(text: shown, style: style, link: SlackMarkup.safeLink(address), block: block))
        }
    }

    /// Code shows its text as written: tokens become their words, escapes are undone, nothing else changes.
    private func literal(_ s: String) -> String {
        SlackText.plain(s, users: names, channels: names)
    }

    /// No blank lines before or after the message.
    private func trim() {
        func isBlank(_ r: Run) -> Bool { !r.isQuoteMark && r.block != .code && r.text.allSatisfy(\.isWhitespace) }
        while let first = runs.first, isBlank(first) { runs.removeFirst() }
        while let last = runs.last, isBlank(last) { runs.removeLast() }
        if var first = runs.first, !first.isQuoteMark, first.block != .code {
            while first.text.first?.isNewline == true { first.text.removeFirst() }
            runs[0] = first
        }
        if var last = runs.last, !last.isQuoteMark, last.block != .code {
            while last.text.last?.isWhitespace == true { last.text.removeLast() }
            runs[runs.count - 1] = last
        }
    }
}
