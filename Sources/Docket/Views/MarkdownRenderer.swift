import AppKit
import UniformTypeIdentifiers

extension NSAttributedString.Key {
    /// On a rendered checkbox: the index of its "- [ ]" line in the source, so a click can toggle it.
    static let docketTaskLine = NSAttributedString.Key("DocketTaskLine")
}

/// Turns Markdown into finished, styled text for reading: headings, emphasis, links, lists,
/// task lists, quotes, code blocks, rules and tables, in the ink-and-paper type ramp.
/// The note itself stays Markdown; this is only how it's shown (and exported).
enum MarkdownRenderer {
    /// `forExport` swaps checkbox images for ☐/☑ glyphs so RTF, HTML and PDF keep them.
    static func render(_ source: String, forExport: Bool = false) -> NSAttributedString {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let out = NSMutableAttributedString()
        var ctx = Context(forExport: forExport)
        renderBlocks(lines, offset: 0, quotes: [], color: Palette.ink, into: out, ctx: &ctx)
        while out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        linkBareURLs(out)
        return out
    }

    private struct Context {
        var forExport: Bool
    }

    // MARK: Type

    static let bodySize: CGFloat = 15

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func bold(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
    private static func italic(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }

    private static func style(before: CGFloat = 0, after: CGFloat = 10, lineSpacing: CGFloat = 4,
                              first: CGFloat = 0, head: CGFloat = 0, tabs: [CGFloat] = [],
                              blocks: [NSTextBlock] = [], alignment: NSTextAlignment = .natural) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineSpacing = lineSpacing
        p.firstLineHeadIndent = first
        p.headIndent = head
        p.tabStops = tabs.map { NSTextTab(textAlignment: .left, location: $0) }
        p.textBlocks = blocks
        p.alignment = alignment
        return p
    }

    // MARK: Block patterns

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    /// Any indent (fences sit deep under nested list items) and a whole info string ("js title=…").
    /// The possessive `*+`s keep a long line from backtracking for seconds.
    private static let fence = re(#"^\s*(`{3,}|~{3,})[ \t]*+([^`\s]*+)[^`]*$"#)
    private static let rule = re(#"^\s{0,3}([-*_])(\s*\1){2,}\s*$"#)
    private static let heading = re(#"^\s{0,3}(#{1,6})(?:\s+(.*))?$"#)
    private static let quote = re(#"^\s{0,3}>\s?(.*)$"#)
    private static let listItem = re(#"^(\s*)([-*+]|\d{1,9}[.)])\s+(?:\[([ xX])\](?:\s+|$))?(.*)$"#)
    private static let tableSeparator = re(#"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)
    private static let setextH1 = re(#"^\s{0,3}=+\s*$"#)
    private static let setextH2 = re(#"^\s{0,3}-+\s*$"#)
    /// A line that is only a picture, video or PDF: ![alt](path "optional title"), or ![alt](<path with spaces>)
    private static let mediaLine = re(#"^\s*!\[([^\]]*)\]\((?:<([^>\n]+)>|([^)\s]+))(?:\s+"[^"]*")?\)\s*$"#)
    /// A line that is only HTML comments (atomic, so a line of many can't backtrack for ever),
    /// and one that opens a comment closed on a later line.
    private static let commentLine = re(#"^\s*(?>(?:<!--.*?-->\s*))+$"#)
    private static let commentStart = re(#"^\s*<!--(?!.*-->)"#)

    private static func match(_ r: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let range = m.range(at: i)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Width of the leading whitespace in columns (a tab counts as four, as for list indents).
    private static func indentation(_ s: String) -> Int {
        var n = 0
        for ch in s {
            if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break }
        }
        return n
    }

    /// `s` without up to `columns` columns of leading whitespace.
    private static func dropIndent(_ s: String, _ columns: Int) -> String {
        var n = 0
        var rest = Substring(s)
        while n < columns, let ch = rest.first, ch == " " || ch == "\t" {
            n += ch == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    /// A closing fence is only the opening fence's character, at least as many times.
    private static func closesFence(_ line: String, _ marker: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= marker.count && t.allSatisfy { $0 == marker.first }
    }

    private static func isTableStart(_ lines: [String], _ i: Int) -> Bool {
        i + 1 < lines.count && lines[i].contains("|") && match(tableSeparator, lines[i + 1]) != nil && lines[i + 1].contains("-")
    }

    /// Does this line start a block other than a paragraph?
    private static func startsBlock(_ lines: [String], _ i: Int) -> Bool {
        let l = lines[i]
        return match(fence, l) != nil || match(rule, l) != nil || match(heading, l) != nil
            || match(quote, l) != nil || match(listItem, l) != nil || isTableStart(lines, i) || match(mediaLine, l) != nil
            || bareMediaURL(l) != nil || bareVideoLink(l) != nil || l.trimmingCharacters(in: .whitespaces).hasPrefix("<!--")
    }

    // MARK: Blocks

    /// `quotes` are the blocks the text sits in (quotes, and list items for blocks indented under them).
    private static func renderBlocks(_ lines: [String], offset: Int, quotes: [NSTextBlock], color textColor: NSColor,
                                     into out: NSMutableAttributedString, ctx: inout Context) {
        var i = 0
        while i < lines.count {
            let line = lines[i]

            if isBlank(line) {
                i += 1
                continue
            }

            // Fenced code (its lines lose the fence's own indent)
            if let f = match(fence, line) {
                let indent = indentation(line)
                let marker = f[1] ?? "```"
                var code: [String] = []
                i += 1
                while i < lines.count, !closesFence(lines[i], marker) {
                    code.append(dropIndent(lines[i], indent))
                    i += 1
                }
                i += 1 // closing fence
                appendCode(code, language: f[2] ?? "", quotes: quotes, into: out)
                continue
            }

            // HTML comments are hidden. Their lines still count, so task line numbers stay right.
            if match(commentLine, line) != nil {
                i += 1
                continue
            }
            if match(commentStart, line) != nil {
                i += 1
                while i < lines.count, !lines[i].contains("-->") { i += 1 }
                i += 1 // the line that closes it
                continue
            }

            // A photo, video or PDF on its own line
            if let m = match(mediaLine, line) {
                appendMedia(path: m[2] ?? m[3] ?? "", alt: m[1] ?? "", quotes: quotes, into: out, ctx: ctx)
                i += 1
                continue
            }

            // A bare link to a picture, video or PDF on the web, or to a YouTube, Vimeo or Loom video,
            // alone on its line. Exports keep it a link.
            let media = bareMediaURL(line)
            if let url = media ?? bareVideoLink(line) {
                var shown = false
                if !ctx.forExport {
                    shown = media != nil ? appendRemote(url, alt: "", quotes: quotes, into: out) : appendVideoLink(url, quotes: quotes, into: out)
                }
                if !shown {
                    let s = inline(line.trimmingCharacters(in: .whitespaces), font: font(bodySize), color: textColor)
                    s.append(NSAttributedString(string: "\n"))
                    s.addAttribute(.paragraphStyle, value: style(blocks: quotes), range: NSRange(location: 0, length: s.length))
                    out.append(s)
                }
                i += 1
                continue
            }

            // Horizontal rule (but "Title\n---" is a heading, handled with paragraphs below)
            if match(rule, line) != nil {
                appendRule(quotes: quotes, into: out)
                i += 1
                continue
            }

            // ATX heading, without its optional closing #s (but keeping the one in "C#").
            // The lookbehind tries each run of spaces once, so a long run can't take seconds.
            if let h = match(heading, line) {
                let level = (h[1] ?? "#").count
                let text = (h[2] ?? "").replacingOccurrences(of: #"(?:^|(?<!\s)\s+)#+\s*$"#, with: "", options: .regularExpression)
                appendHeading(text.trimmingCharacters(in: .whitespaces), level: level, quotes: quotes, color: textColor, into: out)
                i += 1
                continue
            }

            // Block quote: gather consecutive ">" lines and render their content inside a quote block.
            if match(quote, line) != nil {
                var inner: [String] = []
                let start = i
                while i < lines.count, let q = match(quote, lines[i]) {
                    inner.append(q[1] ?? "")
                    i += 1
                }
                let block = NSTextBlock()
                block.setContentWidth(100, type: .percentageValueType)
                block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                block.setBorderColor(Palette.hairStrong, for: .minX)
                block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
                renderBlocks(inner, offset: offset + start, quotes: quotes + [block], color: Palette.ink2, into: out, ctx: &ctx)
                continue
            }

            // Table
            if isTableStart(lines, i) {
                var rows: [String] = [lines[i]]
                let separator = lines[i + 1]
                i += 2
                while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
                    rows.append(lines[i])
                    i += 1
                }
                appendTable(rows, separator: separator, quotes: quotes, into: out)
                continue
            }

            // List (consecutive items, with indented continuation lines)
            if match(listItem, line) != nil {
                i = appendList(lines, from: i, offset: offset, quotes: quotes, color: textColor, into: out, ctx: &ctx)
                continue
            }

            // Paragraph (or a setext heading if underlined with === / ---)
            var para: [String] = [line.trimmingCharacters(in: .whitespaces)]
            i += 1
            var setextLevel = 0
            while i < lines.count, !isBlank(lines[i]) {
                if match(setextH1, lines[i]) != nil { setextLevel = 1; i += 1; break }
                if match(setextH2, lines[i]) != nil { setextLevel = 2; i += 1; break }
                if startsBlock(lines, i) { break }
                para.append(lines[i].trimmingCharacters(in: .whitespaces))
                i += 1
            }
            // Keep the writer's line breaks inside a paragraph (inline() turns them into U+2028).
            let text = para.joined(separator: "\n")
            if setextLevel > 0 {
                appendHeading(text, level: setextLevel, quotes: quotes, color: textColor, into: out)
            } else {
                let s = inline(text, font: font(bodySize), color: textColor)
                s.append(NSAttributedString(string: "\n"))
                s.addAttribute(.paragraphStyle, value: style(blocks: quotes), range: NSRange(location: 0, length: s.length))
                out.append(s)
            }
        }
    }

    private static func appendHeading(_ text: String, level: Int, quotes: [NSTextBlock], color: NSColor, into out: NSMutableAttributedString) {
        let sizes: [CGFloat] = [28, 22, 18, 16, 15, 14]
        let kerns: [CGFloat] = [-0.6, -0.4, -0.3, -0.2, 0, 0]
        let weights: [NSFont.Weight] = [.bold, .bold, .semibold, .semibold, .semibold, .semibold]
        let idx = min(max(level, 1), 6) - 1
        let before: CGFloat = out.length == 0 ? 0 : [22, 18, 14, 12, 10, 10][idx]
        let s = inline(text, font: font(sizes[idx], weights[idx]), color: idx == 5 ? Palette.ink2 : color)
        s.append(NSAttributedString(string: "\n"))
        let range = NSRange(location: 0, length: s.length)
        s.addAttribute(.kern, value: kerns[idx], range: range)
        s.addAttribute(.paragraphStyle, value: style(before: before, after: idx <= 1 ? 8 : 6, lineSpacing: 2, blocks: quotes), range: range)
        out.append(s)
    }

    /// A line that is only a web address (optionally in <>) of a picture, video or PDF.
    static func bareMediaURL(_ line: String) -> URL? {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<"), t.hasSuffix(">") { t = String(t.dropFirst().dropLast()) }
        guard t.count > 10, !t.contains(where: \.isWhitespace), let url = URL(string: t),
              MediaLibrary.remoteKind(of: url) != nil else { return nil }
        return url
    }

    /// A line that is only a YouTube, Vimeo or Loom video link.
    static func bareVideoLink(_ line: String) -> URL? {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<"), t.hasSuffix(">") { t = String(t.dropFirst().dropLast()) }
        guard t.count > 10, !t.contains(where: \.isWhitespace), let url = URL(string: t),
              RemoteMedia.embedEndpoint(for: url) != nil else { return nil }
        return url
    }

    /// A card with the video's thumbnail and title; a click opens it in the browser. False (nothing
    /// added) when the site couldn't describe it, so it stays a link.
    private static func appendVideoLink(_ url: URL, quotes: [NSTextBlock], into out: NSMutableAttributedString) -> Bool {
        let remote = RemoteMedia.shared
        let cell: MediaCardCell
        switch remote.embed(for: url) {
        case .failed:
            return false
        case .loading:
            cell = MediaCardCell(title: url.host ?? url.absoluteString, subtitle: "Loading…", thumbnail: nil,
                                 symbol: "play.rectangle", landscape: true)
        case let .ready(embed):
            var thumbnail: NSImage?
            if let link = embed.thumbnail, case let .ready(file) = remote.file(for: link) {
                thumbnail = MediaCache.shared.image(for: file)
            }
            cell = MediaCardCell(title: embed.title, subtitle: "\(embed.provider) · Video", thumbnail: thumbnail,
                                 symbol: "play.rectangle", landscape: true)
        }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell
        appendAttachment(attachment, opening: url, label: "Video: \(cell.cardTitle)", tip: "Click to watch it in your browser",
                         card: true, quotes: quotes, into: out)
        return true
    }

    private static func appendMedia(path: String, alt: String, quotes: [NSTextBlock],
                                    into out: NSMutableAttributedString, ctx: Context) {
        if let url = MediaLibrary.resolve(path), FileManager.default.fileExists(atPath: url.path),
           let kind = MediaLibrary.kind(of: url),
           appendLocal(url, kind: kind, name: alt.isEmpty ? url.deletingPathExtension().lastPathComponent : alt,
                       quotes: quotes, into: out, ctx: ctx) {
            return
        }
        if !ctx.forExport, let url = URL(string: path), MediaLibrary.isWebURL(url),
           appendRemote(url, alt: alt, quotes: quotes, into: out) {
            return
        }
        appendMediaLink(path: path, alt: alt, quotes: quotes, into: out)
    }

    /// A missing file, a file Docket can't show (an .mkv, say), media on the web in an export, or one
    /// that couldn't be fetched: a link rather than a broken box. A local file opens in its own app.
    private static func appendMediaLink(path: String, alt: String, quotes: [NSTextBlock], into out: NSMutableAttributedString) {
        let web = URL(string: path).flatMap { $0.scheme != nil && !$0.isFileURL ? $0 : nil }
        let label = alt.isEmpty ? (web?.absoluteString ?? URL(string: path)?.lastPathComponent ?? path) : alt
        let local = MediaLibrary.resolve(path).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let ext = (web?.pathExtension ?? (path as NSString).pathExtension).lowercased()
        let prefix: String
        if local != nil {
            prefix = "Attachment: "
        } else {
            switch MediaLibrary.kind(ofExtension: ext) {
            case .video?: prefix = "Video: "
            case .pdf?: prefix = "PDF: "
            default: prefix = "Image: "
            }
        }
        let s = NSMutableAttributedString(string: prefix + label + "\n", attributes: [
            .font: font(bodySize, .medium), .foregroundColor: Palette.ink2,
            .paragraphStyle: style(blocks: quotes),
        ])
        if let link = local ?? web {
            s.addAttribute(.link, value: link, range: NSRange(location: (prefix as NSString).length, length: (label as NSString).length))
        }
        out.append(s)
    }

    /// A photo, video or PDF on this Mac. False (nothing added) for a picture that can't be decoded.
    private static func appendLocal(_ url: URL, kind: MediaLibrary.Kind, name: String, quotes: [NSTextBlock],
                                    into out: NSMutableAttributedString, ctx: Context) -> Bool {
        let attachment = NSTextAttachment()
        let tip: String
        let label: String
        switch kind {
        case .image:
            guard let picture = MediaCache.shared.image(for: url) else { return false }
            if ctx.forExport, let data = try? Data(contentsOf: url) {
                // Made from the bytes: a wrapper made from the URL also puts a large file icon into RTFD.
                let file = FileWrapper(regularFileWithContents: data)
                file.preferredFilename = url.lastPathComponent
                attachment.fileWrapper = file
            }
            attachment.attachmentCell = MediaAttachmentCell(url: url, isVideo: false, picture: picture)
            tip = "Click to see it full size"
            label = "Image: \(name)"
        case .video:
            attachment.attachmentCell = MediaAttachmentCell(url: url, isVideo: true, picture: MediaCache.shared.poster(for: url))
            tip = "Click to play"
            label = "Video: \(name)"
        case .pdf:
            // An export is made in one go, so it reads the PDF now rather than waiting for the cache.
            let summary = ctx.forExport ? PDFSummary.make(for: url) : MediaCache.shared.pdf(for: url)
            attachment.attachmentCell = MediaCardCell(title: name, subtitle: summary?.subtitle ?? "PDF",
                                                      thumbnail: summary?.thumbnail, symbol: "doc.richtext")
            tip = "Click to read it in Quick Look"
            label = "PDF: \(name)"
        }
        appendAttachment(attachment, opening: url, label: label, tip: tip, card: kind == .pdf, quotes: quotes, into: out)
        return true
    }

    /// Media on the web: a placeholder card while it loads, then the picture, video poster or PDF card.
    /// False (nothing added) once fetching it has failed.
    private static func appendRemote(_ url: URL, alt: String, quotes: [NSTextBlock], into out: NSMutableAttributedString) -> Bool {
        let hinted = MediaLibrary.remoteKind(of: url)
        let last = url.deletingPathExtension().lastPathComponent
        let name = alt.isEmpty ? ((last.isEmpty || last == "/") ? (url.host ?? url.absoluteString) : (last.removingPercentEncoding ?? last)) : alt
        let remote = RemoteMedia.shared
        if hinted == .video {
            // Videos aren't downloaded: the poster comes from the web address, and a click opens it.
            switch remote.poster(for: url) {
            case let .ready(poster):
                let attachment = NSTextAttachment()
                attachment.attachmentCell = MediaAttachmentCell(url: url, isVideo: true, picture: poster)
                appendAttachment(attachment, opening: url, label: "Video: \(name)", tip: "Click to play it in your browser",
                                 card: false, quotes: quotes, into: out)
                return true
            case .loading:
                appendPlaceholder(url, kind: .video, name: name, quotes: quotes, into: out)
                return true
            case .failed:
                return false
            }
        }
        switch remote.file(for: url) {
        case let .ready(file):
            guard let kind = MediaLibrary.kind(of: file) else { return false }
            return appendLocal(file, kind: kind, name: name, quotes: quotes, into: out, ctx: Context(forExport: false))
        case .loading:
            appendPlaceholder(url, kind: hinted ?? .image, name: name, quotes: quotes, into: out)
            return true
        case .failed:
            return false
        }
    }

    private static func appendPlaceholder(_ url: URL, kind: MediaLibrary.Kind, name: String, quotes: [NSTextBlock],
                                          into out: NSMutableAttributedString) {
        let symbol: String
        switch kind {
        case .image: symbol = "photo"
        case .video: symbol = "play.rectangle"
        case .pdf: symbol = "doc.richtext"
        }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MediaCardCell(title: name, subtitle: "Loading from \(url.host ?? "the web")…",
                                                  thumbnail: nil, symbol: symbol)
        appendAttachment(attachment, opening: url, label: name, tip: "Still loading. Click to open it in your browser",
                         card: true, quotes: quotes, into: out)
    }

    /// The attachment on a line of its own; a click opens `url`.
    private static func appendAttachment(_ attachment: NSTextAttachment, opening url: URL, label: String, tip: String, card: Bool,
                                         quotes: [NSTextBlock], into out: NSMutableAttributedString) {
        let s = NSMutableAttributedString(attachment: attachment)
        s.addAttributes([.docketMediaURL: url, .docketMediaLabel: label, .cursor: NSCursor.pointingHand, .toolTip: tip],
                        range: NSRange(location: 0, length: s.length))
        s.append(NSAttributedString(string: "\n"))
        s.addAttribute(.paragraphStyle, value: style(before: 4, after: card ? 10 : 14, lineSpacing: 0, blocks: quotes),
                       range: NSRange(location: 0, length: s.length))
        out.append(s)
    }

    private static func appendRule(quotes: [NSTextBlock], into out: NSMutableAttributedString) {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(Palette.hair, for: .maxY)
        block.setWidth(10, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY)
        let s = NSMutableAttributedString(string: "\u{200B}\n", attributes: [
            .font: font(2),
            .paragraphStyle: style(after: 0, lineSpacing: 0, blocks: quotes + [block]),
        ])
        out.append(s)
    }

    private static func appendCode(_ code: [String], language: String, quotes: [NSTextBlock], into out: NSMutableAttributedString) {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.backgroundColor = Palette.fill
        block.setWidth(14, type: .absoluteValueType, for: .padding)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let body = (code.isEmpty ? [""] : code).joined(separator: "\u{2028}")
        let s = NSMutableAttributedString(string: body + "\n", attributes: [
            .font: mono,
            .foregroundColor: Palette.ink,
            .paragraphStyle: style(after: 0, lineSpacing: 3, blocks: quotes + [block]),
        ])
        out.append(s)
    }

    /// A list is read in full before it's laid out, so the numbers of a run can share one text column.
    private enum ListPart {
        /// `run` groups items numbered as one sequence; `line` is the item's index in the lines.
        case item(level: Int, number: Int?, run: Int?, task: String?, text: String, line: Int)
        /// Paragraphs, code and the like indented under the open item at level `owner`.
        case blocks([String], line: Int, owner: Int)
    }

    /// Renders consecutive list items starting at `start`, with the blocks indented under them;
    /// returns the index after the list.
    private static func appendList(_ lines: [String], from start: Int, offset: Int, quotes: [NSTextBlock], color: NSColor,
                                   into out: NSMutableAttributedString, ctx: inout Context) -> Int {
        var i = start
        var indents: [Int] = []          // indentation of each open nesting level
        var columns: [Int] = []          // the column where each open item's text starts
        var counters: [Int: Int] = [:]   // running number per level for ordered lists
        var lastOrdered: [Int: Bool] = [:]
        var runs: [Int: Int] = [:]       // the numbering run each level is in
        var parts: [ListPart] = []

        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                // A blank line continues the list if another item, or more of an open item, follows.
                var next = i + 1
                while next < lines.count, isBlank(lines[next]) { next += 1 }
                guard next < lines.count,
                      match(listItem, lines[next]) != nil || columns.contains(where: { indentation(lines[next]) >= $0 }) else { break }
                i = next
                continue
            }
            guard let m = match(listItem, line) else {
                // Paragraphs, code and the like indented under an item belong to it.
                guard let owner = columns.lastIndex(where: { indentation(line) >= $0 }) else { break }
                let first = i
                var body: [String] = []
                var fenceMarker: String?
                var inComment = false
                while i < lines.count {
                    let l = lines[i]
                    // A fence or comment runs to its closing line, however that and its lines are indented.
                    if let marker = fenceMarker {
                        if closesFence(l, marker) { fenceMarker = nil }
                    } else if inComment {
                        inComment = !l.contains("-->")
                    } else if !isBlank(l), indentation(l) < columns[owner] || match(listItem, l) != nil {
                        break // the item ends, or a nested item is laid out with the rest of the list
                    } else if let f = match(fence, l) {
                        fenceMarker = f[1] ?? "```"
                    } else {
                        inComment = match(commentStart, l) != nil
                    }
                    body.append(dropIndent(l, columns[owner]))
                    i += 1
                }
                parts.append(.blocks(body, line: first, owner: owner))
                // Items nested deeper than the owner are finished.
                columns = Array(columns.prefix(owner + 1))
                indents = Array(indents.prefix(owner + 1))
                for deeper in (owner + 1)..<7 { counters[deeper] = nil; lastOrdered[deeper] = nil }
                continue
            }

            let indent = (m[1] ?? "").replacingOccurrences(of: "\t", with: "    ").count
            while let last = indents.last, indent < last { indents.removeLast() }
            if indents.isEmpty || indent > indents.last! { indents.append(indent) }
            let level = min(indents.count - 1, 5)
            for deeper in (level + 1)..<7 { counters[deeper] = nil; lastOrdered[deeper] = nil }

            // Task items count too, so "1. a / 2. [ ] b / 3. c" keeps its numbers.
            let marker = m[2] ?? "-"
            let ordered = marker.first?.isNumber == true
            var number: Int?
            if ordered {
                let written = Int(marker.dropLast()) ?? 1
                if lastOrdered[level] != true { runs[level] = parts.count }
                let n = lastOrdered[level] == true ? (counters[level] ?? written - 1) + 1 : written
                counters[level] = n
                number = n
            }
            lastOrdered[level] = ordered
            columns = Array(columns.prefix(level)) + [indent + marker.count + 1]
            var text = m[4] ?? ""
            let sourceLine = i
            i += 1

            // Indented continuation lines belong to this item.
            while i < lines.count, !isBlank(lines[i]), match(listItem, lines[i]) == nil, !startsBlock(lines, i),
                  lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") {
                text += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                i += 1
            }
            parts.append(.item(level: level, number: number, run: ordered ? runs[level] : nil, task: m[3], text: text, line: sourceLine))
        }

        // "10." is wider than the usual marker column; a run's items share the column of its widest number.
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .semibold)
        var runWidths: [Int: CGFloat] = [:]
        for case let .item(_, number?, run?, nil, _, _) in parts {
            let width = ceil(("\(number)." as NSString).size(withAttributes: [.font: numberFont]).width)
            runWidths[run] = max(runWidths[run] ?? 0, width)
        }

        var textXs: [CGFloat] = []       // where the text of each open level starts
        for part in parts {
            switch part {
            case let .blocks(body, line, owner):
                let block = NSTextBlock()
                block.setContentWidth(100, type: .percentageValueType)
                block.setWidth(owner < textXs.count ? textXs[owner] : 0, type: .absoluteValueType, for: .margin, edge: .minX)
                renderBlocks(body, offset: offset + line, quotes: quotes + [block], color: color, into: out, ctx: &ctx)
            case let .item(level, number, run, task, text, line):
                // A nested item's marker sits where its parent's text starts.
                let markerX = level > 0 && level <= textXs.count ? textXs[level - 1] : 4 + CGFloat(level) * 22
                let textX = markerX + max(22, (run.flatMap { runWidths[$0] } ?? 0) + 6)
                textXs = Array(textXs.prefix(level)) + [textX]
                let item = NSMutableAttributedString()
                if let task {
                    let done = task != " "
                    item.append(checkbox(done: done, line: offset + line, export: ctx.forExport))
                    item.append(NSAttributedString(string: "\t"))
                    let body = inline(text, font: font(bodySize), color: done ? Palette.ink3 : color)
                    if done {
                        body.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: body.length))
                    }
                    item.append(body)
                } else {
                    let symbol = number.map { "\($0)." } ?? ["•", "◦", "▪", "•", "◦", "▪"][level]
                    item.append(NSAttributedString(string: symbol + "\t", attributes: [
                        .font: number != nil ? numberFont : font(bodySize, .bold),
                        .foregroundColor: Palette.ink2,
                    ]))
                    item.append(inline(text, font: font(bodySize), color: color))
                }
                item.append(NSAttributedString(string: "\n"))
                item.addAttribute(.paragraphStyle,
                                  value: style(after: 5, lineSpacing: 3, first: markerX, head: textX, tabs: [textX], blocks: quotes),
                                  range: NSRange(location: 0, length: item.length))
                out.append(item)
            }
        }
        // A little air after the list (blocks under its last item keep their own spacing).
        if case .item? = parts.last, out.length > 0 {
            let last = (out.string as NSString).paragraphRange(for: NSRange(location: out.length - 1, length: 0))
            if let p = (out.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                p.paragraphSpacing = 12
                out.addAttribute(.paragraphStyle, value: p, range: last)
            }
        }
        return i
    }

    private static func checkbox(done: Bool, line: Int, export: Bool) -> NSAttributedString {
        if export {
            return NSAttributedString(string: done ? "☑" : "☐", attributes: [
                .font: font(bodySize), .foregroundColor: done ? Palette.ink : Palette.ink2, .docketTaskLine: line,
            ])
        }
        let attachment = NSTextAttachment()
        attachment.image = checkboxImage(done: done)
        attachment.bounds = CGRect(x: 0, y: -3, width: 17, height: 17)
        let s = NSMutableAttributedString(attachment: attachment)
        s.addAttributes([.docketTaskLine: line, .cursor: NSCursor.pointingHand], range: NSRange(location: 0, length: s.length))
        return s
    }

    /// Matches CheckCircle: an ink3 ring, or an ink disc with a paper tick. Drawn at display time,
    /// so it follows light/dark.
    private static func checkboxImage(done: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: 17), flipped: false) { rect in
            let circle = rect.insetBy(dx: 1, dy: 1)
            if done {
                Palette.ink.setFill()
                NSBezierPath(ovalIn: circle).fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: circle.minX + 4.2, y: circle.midY + 0.2))
                tick.line(to: NSPoint(x: circle.minX + 6.6, y: circle.midY - 2.6))
                tick.line(to: NSPoint(x: circle.maxX - 3.8, y: circle.midY + 2.8))
                tick.lineWidth = 1.8
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                Palette.onPrimary.setStroke()
                tick.stroke()
            } else {
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                Palette.ink3.setStroke()
                ring.stroke()
            }
            return true
        }
        image.accessibilityDescription = done ? "Done" : "Not done"
        return image
    }

    private static func appendTable(_ rows: [String], separator: String, quotes: [NSTextBlock], into out: NSMutableAttributedString) {
        func cells(_ row: String) -> [String] {
            var r = row.trimmingCharacters(in: .whitespaces)
            if r.hasPrefix("|") { r.removeFirst() }
            if r.hasSuffix("|") && !r.hasSuffix("\\|") { r.removeLast() }
            // Split on pipes that aren't escaped.
            var result: [String] = [], current = "", escaped = false
            for ch in r {
                if escaped { current.append(ch); escaped = false; continue }
                if ch == "\\" { escaped = true; current.append(ch); continue }
                if ch == "|" { result.append(current); current = ""; continue }
                current.append(ch)
            }
            result.append(current)
            return result.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
        }

        let alignments: [NSTextAlignment] = cells(separator).map { spec in
            let left = spec.hasPrefix(":"), right = spec.hasSuffix(":")
            return left && right ? .center : (right ? .right : .left)
        }
        let parsed = rows.map(cells)
        let columns = max(parsed.map(\.count).max() ?? 1, alignments.count, 1)

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.setContentWidth(100, type: .percentageValueType)
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        table.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY)

        for (r, row) in parsed.enumerated() {
            for c in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(Palette.hair)
                block.setWidth(8, type: .absoluteValueType, for: .padding)
                if r == 0 { block.backgroundColor = Palette.fill }
                let text = c < row.count ? row[c] : ""
                let cell = inline(text, font: font(13.5, r == 0 ? .semibold : .regular), color: Palette.ink)
                cell.append(NSAttributedString(string: "\n"))
                let alignment = c < alignments.count ? alignments[c] : .left
                cell.addAttribute(.paragraphStyle, value: style(after: 0, lineSpacing: 2, blocks: quotes + [block], alignment: alignment),
                                  range: NSRange(location: 0, length: cell.length))
                out.append(cell)
            }
        }
    }

    // MARK: Inline

    /// Bold, italic, `code`, ~~strike~~, links and images, via Foundation's Markdown parser.
    /// Line breaks go in as "\n" (the parser misses emphasis next to a U+2028) and come out as U+2028,
    /// a new line in the same paragraph.
    static func inline(_ text: String, font base: NSFont, color: NSColor) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSMutableAttributedString(string: text.replacingOccurrences(of: "\n", with: "\u{2028}"),
                                             attributes: [.font: base, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var piece = String(parsed[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            if run.inlinePresentationIntent?.contains(.inlineHTML) == true {
                piece = shownHTML(piece)
                if piece.isEmpty { continue }
            }
            var f = base
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { f = bold(f) }
                if intent.contains(.emphasized) { f = italic(f) }
                if intent.contains(.code) {
                    f = NSFont.monospacedSystemFont(ofSize: f.pointSize * 0.88, weight: .medium)
                    attrs[.backgroundColor] = Palette.fill
                }
                if intent.contains(.strikethrough) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.foregroundColor] = Palette.ink3
                }
            }
            if let url = run.link {
                attrs[.link] = url
            } else if let image = run.imageURL {
                attrs[.link] = image
            }
            attrs[.font] = f
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    private static let lineBreakTag = re(#"(?i)</?br\s*/?>"#)
    /// Comments and tags that only style their text (which still shows). Other HTML, such as a
    /// "<branch>" placeholder or <del>, shows as typed.
    private static let hiddenHTML = re(#"(?i)<!--[\s\S]*?-->|</?(?:abbr|b|big|cite|code|dfn|em|font|i|kbd|mark|samp|small|span|strong|tt|u|var)\b[^>]*>"#)

    /// What inline HTML shows as: <br> is a line break (the only way to get one in a table cell).
    private static func shownHTML(_ html: String) -> String {
        let breaks = lineBreakTag.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length),
                                                           withTemplate: "\u{2028}")
        return hiddenHTML.stringByReplacingMatches(in: breaks, range: NSRange(location: 0, length: (breaks as NSString).length),
                                                   withTemplate: "")
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Plain URLs in the text become links too.
    private static func linkBareURLs(_ s: NSMutableAttributedString) {
        guard let linkDetector else { return }
        let full = NSRange(location: 0, length: s.length)
        for m in linkDetector.matches(in: s.string, range: full) {
            guard let url = m.url, s.attribute(.link, at: m.range.location, effectiveRange: nil) == nil else { continue }
            if let f = s.attribute(.font, at: m.range.location, effectiveRange: nil) as? NSFont, f.isFixedPitch { continue }
            s.addAttribute(.link, value: url, range: m.range)
        }
    }
}

// MARK: - Export

@MainActor
enum MarkdownExport {
    /// Puts the formatted note on the clipboard (rich text and HTML for Mail, Pages, Docs) plus the Markdown.
    static func copyFormatted(_ markdown: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        for (type, data) in formattedData(markdown) { pb.setData(data, forType: type) }
        pb.setString(markdown, forType: .string)
    }

    private static let webArchiveType = NSPasteboard.PasteboardType("com.apple.webarchive")

    /// The formatted note in each rich format. RTF can't hold photos, so they travel in RTFD (Pages, TextEdit),
    /// the web archive (Mail) and the HTML (for browsers).
    static func formattedData(_ markdown: String) -> [(NSPasteboard.PasteboardType, Data)] {
        var flavors: [(NSPasteboard.PasteboardType, Data?)] = []
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            let rendered = resolved(namingUnembeddedMedia(MarkdownRenderer.render(markdown, forExport: true)))
            let range = NSRange(location: 0, length: rendered.length)
            func data(_ type: NSAttributedString.DocumentType) -> Data? {
                try? rendered.data(from: range, documentAttributes: [.documentType: type])
            }
            flavors = [
                (.rtfd, rendered.rtfd(from: range, documentAttributes: [:])),
                (.rtf, data(.rtf)),
                (webArchiveType, data(.webArchive)),
                (.html, data(.html).map { embeddingImages($0, from: rendered) }),
            ]
        }
        return flavors.compactMap { type, data in data.map { (type, $0) } }
    }

    private static let fileImage = try! NSRegularExpression(pattern: #"<img\b[^>]*?\bsrc="(file:[^"]*)"[^>]*>"#)

    /// HTML export points each photo at "file:///<name>", which no other app can open. Formats every
    /// browser shows go in as data URLs; other photos are left out rather than shown broken.
    private static func embeddingImages(_ html: Data, from s: NSAttributedString) -> Data {
        guard let text = String(data: html, encoding: .utf8) else { return html }
        var files: [String: Data] = [:]
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            guard let file = (value as? NSTextAttachment)?.fileWrapper, let name = file.preferredFilename,
                  let contents = file.regularFileContents else { return }
            files[name] = contents
        }
        let out = NSMutableString(string: text)
        for m in fileImage.matches(in: text, range: NSRange(location: 0, length: out.length)).reversed() {
            let name = URL(string: out.substring(with: m.range(at: 1)))?.lastPathComponent ?? ""
            let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? ""
            if let contents = files[name], ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) {
                out.replaceCharacters(in: m.range(at: 1), with: "data:\(mime);base64,\(contents.base64EncodedString())")
            } else {
                out.replaceCharacters(in: m.range, with: "")
            }
        }
        return Data((out as String).utf8)
    }

    /// Saves the formatted note as a PDF (always in the light theme).
    static func exportPDF(_ markdown: String, title: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.topMargin = 56
        info.bottomMargin = 56
        info.leftMargin = 60
        info.rightMargin = 60
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: container)
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.isVerticallyResizable = true
        storage.setAttributedString(MarkdownRenderer.render(markdown, forExport: true))
        layout.ensureLayout(for: container)
        view.setFrameSize(NSSize(width: width, height: max(100, layout.usedRect(for: container).height + 8)))

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.run()
    }

    /// Rich text only carries attachments made from file bytes (photos). PDF cards and videos would
    /// vanish, so they go in as their label ("PDF: Board deck") instead.
    private static func namingUnembeddedMedia(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        var replacements: [(NSRange, String)] = []
        m.enumerateAttribute(.attachment, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, attachment.fileWrapper == nil,
                  let label = m.attribute(.docketMediaLabel, at: range.location, effectiveRange: nil) as? String else { return }
            replacements.append((range, label))
        }
        for (range, label) in replacements.reversed() {
            let style = m.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
            var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: MarkdownRenderer.bodySize, weight: .medium),
                                                        .foregroundColor: Palette.ink2]
            if let style { attrs[.paragraphStyle] = style }
            m.replaceCharacters(in: range, with: NSAttributedString(string: label, attributes: attrs))
        }
        return m
    }

    /// Dynamic theme colours resolved to the current (light) appearance, for formats that store fixed colours.
    private static func resolved(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        let full = NSRange(location: 0, length: m.length)
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor] {
            m.enumerateAttribute(key, in: full) { value, range, _ in
                if let c = value as? NSColor, let fixed = c.usingColorSpace(.sRGB) { m.addAttribute(key, value: fixed, range: range) }
            }
        }
        return m
    }
}
