import Foundation
import UniformTypeIdentifiers

// MIME for email. The parts of a message come from Gmail's format=full payload (bodies there are base64url
// and already transfer-decoded; see `MIMEPart(gmail:)` in GmailClient.swift) or from a raw RFC 5322 message
// (`MailMIME.parse`: nested multipart/alternative, mixed and related, base64, quoted-printable, 7bit and
// 8bit). Both read the same way: charsets, header parameters (RFC 2231 and encoded-word file names), and
// what a reader sees (`MailBody`): the text and HTML bodies, files and inline images (Content-ID), text
// taken from HTML when there's no text part, and a reply without its quoted history (`MailQuote`).

// MARK: - Parts

/// One header field, unfolded: "Content-Type" → "text/plain; charset=UTF-8".
struct MIMEHeader: Hashable, Sendable {
    var name: String
    var value: String
}

/// One part of an email, and the parts inside it.
struct MIMEPart: Hashable, Sendable {
    var headers: [MIMEHeader] = []
    /// "text/html": lowercased, without parameters.
    var mimeType = "text/plain"
    /// The content, transfer encoding undone. Nil for a container, and for a body Gmail keeps apart
    /// (`attachmentID`).
    var body: Data?
    var parts: [MIMEPart] = []
    /// From Gmail: the part's id ("0.1"), the id its body is fetched with, and its (decoded) file name.
    var partID: String?
    var attachmentID: String?
    var gmailFilename: String?
    /// The body's size in bytes, as Gmail reported it or as read.
    var size: Int?

    /// The first header with this name, in any case.
    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentType: MIMEHeaderValue { MIMEHeaderValue(header("Content-Type") ?? mimeType) }
    var disposition: MIMEHeaderValue? { header("Content-Disposition").map(MIMEHeaderValue.init) }

    /// "<image001.png@01D9C2>" → "image001.png@01D9C2".
    var contentID: String? {
        guard let raw = header("Content-ID") else { return nil }
        let id = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>").union(.whitespacesAndNewlines))
        return id.isEmpty ? nil : id
    }

    /// Gmail's file name, else Content-Disposition's filename, else Content-Type's name.
    var filename: String? {
        for case let name? in [gmailFilename, disposition?.parameters["filename"], contentType.parameters["name"]] {
            let clean = MailText.decodeEncodedWords(name).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    /// The part `path` leads to (child indexes, starting here).
    subscript(path path: [Int]) -> MIMEPart {
        get { path.reduce(self) { $0.parts[$1] } }
        set {
            guard let first = path.first else {
                self = newValue
                return
            }
            parts[first][path: Array(path.dropFirst())] = newValue
        }
    }
}

/// A structured header value and its parameters:
/// `attachment; filename*=UTF-8''%E2%82%AC%20rates.pdf` → "attachment", ["filename": "€ rates.pdf"].
/// RFC 2231 parameters (a charset, continuations `name*0*`, `name*1`) are put back together and decoded,
/// and so are RFC 2047 encoded words, which many mailers use in file names although they shouldn't.
struct MIMEHeaderValue: Hashable, Sendable {
    /// Lowercased: "text/plain", "attachment".
    var value: String
    /// Lowercased names, decoded values.
    var parameters: [String: String]

    init(_ raw: String) {
        let pieces = Self.split(raw)
        value = (pieces.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var plain: [String: String] = [:]
        var extended: [String: [Int: (text: String, encoded: Bool)]] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            var name = piece[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let text = Self.unquoted(piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines))
            guard !name.isEmpty else { continue }
            guard name.contains("*") else {
                if plain[name] == nil { plain[name] = text }
                continue
            }
            // name*=charset'language'text, or numbered pieces: name*0*=…, name*1=…
            let encoded = name.hasSuffix("*")
            if encoded { name.removeLast() }
            var index = 0
            if let star = name.firstIndex(of: "*") {
                guard let number = Int(name[name.index(after: star)...]), (0..<1000).contains(number) else { continue }
                index = number
                name = String(name[..<star])
            }
            extended[name, default: [:]][index] = (text, encoded)
        }
        var parameters = plain.mapValues(MailText.decodeEncodedWords)
        for (name, segments) in extended {
            if let joined = Self.joined(segments) { parameters[name] = joined }
        }
        self.parameters = parameters
    }

    /// Splits at semicolons outside quotes.
    private static func split(_ raw: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for c in raw {
            if escaped {
                escaped = false
            } else if c == "\\", quoted {
                escaped = true
            } else if c == "\"" {
                quoted.toggle()
            } else if c == ";", !quoted {
                pieces.append(current)
                current = ""
                continue
            }
            current.append(c)
        }
        pieces.append(current)
        return pieces
    }

    /// `"Q3 \"final\".pdf"` → `Q3 "final".pdf`.
    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return text }
        var out = ""
        var escaped = false
        for c in text.dropFirst().dropLast() {
            if !escaped, c == "\\" {
                escaped = true
                continue
            }
            escaped = false
            out.append(c)
        }
        return out
    }

    /// RFC 2231: pieces 0, 1, 2… in order. Encoded ones are percent-encoded bytes in the charset the first
    /// one names ("UTF-8'en'…").
    private static func joined(_ segments: [Int: (text: String, encoded: Bool)]) -> String? {
        var bytes: [UInt8] = []
        var charset: String?
        var index = 0
        while let segment = segments[index] {
            var text = segment.text
            if index == 0, segment.encoded {
                let fields = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if fields.count == 3 {
                    charset = fields[0].isEmpty ? nil : String(fields[0])
                    text = String(fields[2])
                }
            }
            bytes += segment.encoded ? percentDecoded(text) : Array(text.utf8)
            index += 1
        }
        guard index > 0 else { return nil }
        return MailCharset.decode(Data(bytes), charset: charset ?? "utf-8")
    }

    private static func percentDecoded(_ text: String) -> [UInt8] {
        let utf8 = Array(text.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "%"), i + 2 < utf8.count, let high = hexValue(utf8[i + 1]), let low = hexValue(utf8[i + 2]) {
                out.append(high << 4 | low)
                i += 3
            } else {
                out.append(utf8[i])
                i += 1
            }
        }
        return out
    }
}

/// The value of an ASCII hex digit.
private func hexValue(_ c: UInt8) -> UInt8? {
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
    case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
    case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
    default: nil
    }
}

// MARK: - Charsets and transfer encodings

/// Bytes in a declared charset, as text.
enum MailCharset {
    /// UTF-8, ISO-8859-1, Windows-1252 and US-ASCII directly; any other IANA name Foundation knows; else
    /// lossy UTF-8. Labels are often wrong, so text that's valid UTF-8 reads as UTF-8 even when it says
    /// Latin-1 or ASCII (or nothing), and "ISO-8859-1" reads as Windows-1252, as browsers do.
    static func decode(_ data: Data, charset: String?) -> String {
        let name = (charset ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespacesAndNewlines)).lowercased()
        switch name {
        case "utf-8", "utf8", "unicode-1-1-utf-8":
            return String(decoding: data, as: UTF8.self)
        case "", "us-ascii", "ascii", "ansi_x3.4-1968", "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "latin-1", "l1",
             "windows-1252", "cp1252", "x-cp1252", "unknown", "x-unknown", "unknown-8bit", "x-user-defined":
            return String(data: data, encoding: .utf8) ?? windows1252(data)
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return text
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func windows1252(_ data: Data) -> String {
        String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Base64 as Gmail and MIME use it.
enum MailBase64 {
    /// Gmail's base64url ("-" and "_" instead of "+" and "/"; padding optional). Nil when it isn't base64.
    static func decodeURLSafe(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count + 3)
        for c in text.utf8 {
            switch c {
            case UInt8(ascii: "-"): bytes.append(UInt8(ascii: "+"))
            case UInt8(ascii: "_"): bytes.append(UInt8(ascii: "/"))
            case UInt8(ascii: "="), UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"): continue
            default: bytes.append(c)
            }
        }
        guard padded(&bytes) else { return nil }
        return Data(base64Encoded: Data(bytes))
    }

    /// base64url without padding: how Gmail takes a `raw` message.
    static func urlSafe(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A MIME body in base64. Line breaks and stray characters are skipped, and missing padding is fine.
    static func decodeLenient(_ input: some Collection<UInt8>) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(input.count)
        for c in input {
            switch c {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "+"), UInt8(ascii: "/"):
                bytes.append(c)
            case UInt8(ascii: "-"): bytes.append(UInt8(ascii: "+"))
            case UInt8(ascii: "_"): bytes.append(UInt8(ascii: "/"))
            default: continue
            }
        }
        // A cut-off last character carries no whole byte.
        if bytes.count % 4 == 1 { bytes.removeLast() }
        guard padded(&bytes), let data = Data(base64Encoded: Data(bytes)) else { return Data() }
        return data
    }

    /// Pads to a multiple of four; false when nothing can make it whole.
    private static func padded(_ bytes: inout [UInt8]) -> Bool {
        switch bytes.count % 4 {
        case 1: return false
        case 2: bytes += [UInt8(ascii: "="), UInt8(ascii: "=")]
        case 3: bytes.append(UInt8(ascii: "="))
        default: break
        }
        return true
    }
}

/// Quoted-printable (RFC 2045): "=C3=A9" is a byte, and "=" at the end of a line joins it to the next.
enum QuotedPrintable {
    static func decode(_ input: some Collection<UInt8>) -> Data {
        let bytes = Array(input)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            let hasBreak = end < bytes.count
            var stop = end
            let crlf = stop > start && bytes[stop - 1] == 0x0D
            if crlf { stop -= 1 }
            // Spaces at the end of a line were added on the way.
            while stop > start, bytes[stop - 1] == 0x20 || bytes[stop - 1] == 0x09 { stop -= 1 }
            var soft = false
            var i = start
            while i < stop {
                if bytes[i] == UInt8(ascii: "=") {
                    if i + 1 == stop {
                        soft = true
                        break
                    }
                    if i + 2 < stop, let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) {
                        out.append(high << 4 | low)
                        i += 3
                        continue
                    }
                }
                // Anything else, a stray "=" too, stays as it is.
                out.append(bytes[i])
                i += 1
            }
            if hasBreak, !soft {
                if crlf { out.append(0x0D) }
                out.append(0x0A)
            }
            start = end + 1
        }
        return Data(out)
    }
}

// MARK: - Raw messages

/// Raw RFC 5322 messages, and parts of them: the headers, then the body, multiparts split and each body's
/// transfer encoding undone.
enum MailMIME {
    /// Deeper or bigger than this isn't a real email; the rest is left out.
    static let maxDepth = 24
    static let maxParts = 500

    static func parse(_ data: Data) -> MIMEPart {
        var budget = maxParts
        return parse(Array(data)[...], depth: 0, budget: &budget)
    }

    /// base64 and quoted-printable decoded; 7bit, 8bit and binary are the bytes as they are.
    static func decode(_ bytes: some Collection<UInt8>, transferEncoding: String?) -> Data {
        switch (transferEncoding ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "base64": MailBase64.decodeLenient(bytes)
        case "quoted-printable": QuotedPrintable.decode(bytes)
        default: Data(bytes)
        }
    }

    private static func parse(_ bytes: ArraySlice<UInt8>, depth: Int, budget: inout Int) -> MIMEPart {
        budget -= 1
        let (head, rest) = splitHead(bytes)
        var part = MIMEPart()
        part.headers = headers(head)
        let type = part.contentType
        part.mimeType = type.value.contains("/") ? type.value : "text/plain"
        if part.mimeType.hasPrefix("multipart/") {
            if let boundary = type.parameters["boundary"], !boundary.isEmpty {
                guard depth < maxDepth else { return part }
                for chunk in bodies(of: rest, boundary: boundary) {
                    guard budget > 0 else { break }
                    part.parts.append(parse(chunk, depth: depth + 1, budget: &budget))
                }
                return part
            }
            // A multipart without a boundary can't be split: read it as text.
            part.mimeType = "text/plain"
        }
        let body = decode(rest, transferEncoding: part.header("Content-Transfer-Encoding"))
        part.body = body
        part.size = body.count
        if part.mimeType == "message/rfc822", depth < maxDepth, budget > 0 {
            part.parts = [parse(Array(body)[...], depth: depth + 1, budget: &budget)]
        }
        return part
    }

    /// The header block, and the body after the first empty line. A part that starts with an empty line, or
    /// with something that isn't a header, has no headers.
    private static func splitHead(_ bytes: ArraySlice<UInt8>) -> (head: ArraySlice<UInt8>, body: ArraySlice<UInt8>) {
        var lineStart = bytes.startIndex
        var first = true
        while lineStart < bytes.endIndex {
            let newline = bytes[lineStart...].firstIndex(of: 0x0A)
            var line = bytes[lineStart..<(newline ?? bytes.endIndex)]
            if line.last == 0x0D { line = line.dropLast() }
            if line.isEmpty {
                return (bytes[bytes.startIndex..<lineStart], newline.map { bytes[($0 + 1)...] } ?? bytes[bytes.endIndex...])
            }
            if first, !looksLikeHeader(line) { return (bytes[bytes.startIndex..<bytes.startIndex], bytes) }
            first = false
            guard let newline else { break }
            lineStart = newline + 1
        }
        return (bytes, bytes[bytes.endIndex...])
    }

    private static func looksLikeHeader(_ line: ArraySlice<UInt8>) -> Bool {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")), colon > line.startIndex else { return false }
        return line[line.startIndex..<colon].allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }

    /// Header fields, folded lines joined. Raw UTF-8 in headers (RFC 6532) reads as UTF-8.
    private static func headers(_ head: ArraySlice<UInt8>) -> [MIMEHeader] {
        guard !head.isEmpty else { return [] }
        let text = MailText.normalizedNewlines(MailCharset.decode(Data(head), charset: nil))
        var fields: [MIMEHeader] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t" {
                // A folded line goes on with the field above.
                guard !fields.isEmpty else { continue }
                let more = line.trimmingCharacters(in: .whitespaces)
                let value = fields[fields.count - 1].value
                fields[fields.count - 1].value = value.isEmpty ? more : value + " " + more
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            fields.append(MIMEHeader(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return fields
    }

    /// The parts of a multipart body: what's between "--boundary" lines, up to "--boundary--". The line
    /// break before each delimiter belongs to the delimiter. A message cut off before the closing delimiter
    /// keeps what arrived.
    private static func bodies(of bytes: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delimiter = Array("--\(boundary)".utf8)
        var bodies: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var lineStart = bytes.startIndex
        while lineStart < bytes.endIndex {
            let newline = bytes[lineStart...].firstIndex(of: 0x0A)
            let line = bytes[lineStart..<(newline ?? bytes.endIndex)]
            if line.starts(with: delimiter) {
                let rest = line.dropFirst(delimiter.count)
                let closing = rest.starts(with: [0x2D, 0x2D])
                if closing || rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                    if let start = partStart {
                        var end = lineStart
                        if end > start, bytes[end - 1] == 0x0A { end -= 1 }
                        if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                        bodies.append(bytes[start..<end])
                    }
                    if closing { return bodies }
                    partStart = newline.map { $0 + 1 } ?? bytes.endIndex
                }
            }
            guard let newline else { break }
            lineStart = newline + 1
        }
        if let start = partStart, start < bytes.endIndex { bodies.append(bytes[start...]) }
        return bodies
    }
}

// MARK: - What a reader sees

/// An email's text and HTML bodies and its files, as a mail app shows them.
struct MailBody: Hashable, Sendable {
    /// An attached file, or an inline image.
    struct File: Hashable, Sendable {
        var name: String
        var mimeType: String
        var size: Int?
        /// The part's Content-ID, only when the HTML body shows it (`cid:`): it's in the body then, not in
        /// the file list.
        var contentID: String?
        var partID: String?
        var attachmentID: String?
        /// The bytes, when they came with the message (a raw message, a small part from Gmail).
        var data: Data?
    }

    /// The text body (its text/plain parts, in order), when there is one.
    var text: String?
    /// The HTML body, when there is one.
    var html: String?
    var files: [File] = []

    /// The text body, or text taken from the HTML when there's no text part.
    var readableText: String {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return html.map { MailText.plainText(fromHTML: $0) } ?? ""
    }
}

extension MailBody {
    init(_ root: MIMEPart) {
        var found = Self.collect(root, depth: 0)
        // Only a text part with a file name: some mailers name the body, so read it as one.
        if found.texts.allSatisfy(\.isBlank), found.htmls.allSatisfy(\.isBlank), let part = found.namedBodies.first {
            let text = Self.decodedText(part)
            if part.mimeType == "text/html" { found.htmls = [text] } else { found.texts = [text] }
            found.files.removeAll { $0 == part }
        }
        let texts = found.texts.map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isBlank }
        let htmls = found.htmls.filter { !$0.isBlank }
        let html = htmls.isEmpty ? nil : htmls.joined(separator: "\n")
        let shown = html.map(Self.shownContentIDs(in:)) ?? []
        self.init(text: texts.isEmpty ? nil : texts.joined(separator: "\n\n"), html: html,
                  files: found.files.compactMap { File($0, shownContentIDs: shown) })
    }

    private struct Found {
        var texts: [String] = []
        var htmls: [String] = []
        var files: [MIMEPart] = []
        /// Text or HTML parts with a file name, shown inline.
        var namedBodies: [MIMEPart] = []

        mutating func add(_ other: Found) {
            texts += other.texts
            htmls += other.htmls
            files += other.files
            namedBodies += other.namedBodies
        }
    }

    /// Signatures (S/MIME, PGP) aren't files anyone opens.
    private static let signatureTypes: Set<String> = ["application/pkcs7-signature", "application/x-pkcs7-signature", "application/pgp-signature"]

    private static func collect(_ part: MIMEPart, depth: Int) -> Found {
        var found = Found()
        guard depth <= MailMIME.maxDepth else { return found }
        let type = part.mimeType
        if type.hasPrefix("multipart/") {
            let children = part.parts.map { collect($0, depth: depth + 1) }
            guard type == "multipart/alternative" else {
                children.forEach { found.add($0) }
                return found
            }
            // Versions of one message, plainest first: the last text and the last HTML, and every file.
            found.texts = children.last { !$0.texts.isEmpty }?.texts ?? []
            found.htmls = children.last { !$0.htmls.isEmpty }?.htmls ?? []
            for child in children {
                found.files += child.files
                found.namedBodies += child.namedBodies
            }
            return found
        }
        if signatureTypes.contains(type) { return found }
        let isAttachment = part.disposition?.value == "attachment"
        let named = part.filename != nil
        if type == "text/plain" || type == "text/html", !isAttachment {
            if named {
                found.namedBodies.append(part)
                found.files.append(part)
            } else if type == "text/html" {
                found.htmls.append(decodedText(part))
            } else {
                found.texts.append(decodedText(part))
            }
            return found
        }
        // An email inside this one, sent inline (not as a file): its text reads as part of the message.
        if type == "message/rfc822", !isAttachment, !named, part.attachmentID == nil, !part.parts.isEmpty {
            part.parts.forEach { found.add(collect($0, depth: depth + 1)) }
            return found
        }
        found.files.append(part)
        return found
    }

    /// A text part's characters: its charset (for HTML without one, its <meta> charset), "\n" line breaks,
    /// and format=flowed lines joined.
    static func decodedText(_ part: MIMEPart) -> String {
        let type = part.contentType
        let data = part.body ?? Data()
        var charset = type.parameters["charset"]
        if charset == nil, part.mimeType == "text/html" { charset = MailText.declaredCharset(inHTML: data) }
        var text = MailText.normalizedNewlines(MailCharset.decode(data, charset: charset))
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if part.mimeType == "text/plain", type.parameters["format"]?.lowercased() == "flowed" {
            text = MailText.unflowed(text, deletingSpace: type.parameters["delsp"]?.lowercased() == "yes")
        }
        return text
    }

    /// `src="cid:…"`, `background="cid:…"` and `url(cid:…)`: where an HTML body shows its own parts.
    private static let contentIDReference = try! NSRegularExpression(
        pattern: #"(?:\b(?:src|background)\s*=\s*["']?\s*|url\(\s*["']?\s*)cid:([^"'\s)>]+)"#, options: [.caseInsensitive])

    /// The Content-IDs the HTML shows inline (normalized).
    static func shownContentIDs(in html: String) -> Set<String> {
        guard html.range(of: "cid:", options: .caseInsensitive) != nil else { return [] }
        let ns = html as NSString
        return Set(contentIDReference.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { normalizedContentID(ns.substring(with: $0.range(at: 1))) }
            .filter { !$0.isEmpty })
    }

    /// "<Image001.PNG@01D9>" and "image001.png%4001D9" are the same part.
    static func normalizedContentID(_ raw: String) -> String {
        (raw.removingPercentEncoding ?? raw).trimmingCharacters(in: CharacterSet(charactersIn: "<>").union(.whitespacesAndNewlines)).lowercased()
    }

    /// A name that's safe to save a file under: no folders, colons or control characters, not hidden,
    /// not absurdly long.
    static func safeFileName(_ name: String) -> String {
        var clean = String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == "\\" || scalar == ":" ? "-" : scalar
        }))
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }
        guard clean.count > 200 else { return clean }
        let ext = (clean as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 10 else { return String(clean.prefix(200)) }
        return String(clean.prefix(199 - ext.count)) + "." + ext
    }

    /// "Image.png", "Attachment.pdf": for a file sent without a name.
    static func defaultFileName(for mimeType: String) -> String {
        switch mimeType {
        case "message/rfc822": return "Message.eml"
        case "text/calendar": return "Invite.ics"
        default:
            let base = mimeType.hasPrefix("image/") ? "Image" : "Attachment"
            guard let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension else { return base }
            return "\(base).\(ext)"
        }
    }
}

extension MailBody.File {
    /// The part as a file; nil when it's empty with nothing to fetch.
    init?(_ part: MIMEPart, shownContentIDs: Set<String>) {
        guard part.attachmentID != nil || part.body?.isEmpty == false else { return nil }
        var type = part.mimeType
        let name = part.filename.map(MailBody.safeFileName).flatMap { $0.isEmpty ? nil : $0 }
        // "application/octet-stream" says nothing; the file name usually does.
        if type == "application/octet-stream" || !type.contains("/"), let name,
           let known = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType {
            type = known
        }
        let contentID = part.contentID.flatMap { shownContentIDs.contains(MailBody.normalizedContentID($0)) ? $0 : nil }
        self.init(name: name ?? MailBody.defaultFileName(for: type), mimeType: type, size: part.size ?? part.body?.count,
                  contentID: contentID, partID: part.partID, attachmentID: part.attachmentID,
                  data: part.attachmentID == nil ? part.body : nil)
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Plain text

extension MailText {
    /// "\r\n" and "\r" as "\n".
    static func normalizedNewlines(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// What an HTML email says, as plain text: no tags, styles, scripts or hidden parts, entities decoded,
    /// paragraphs and line breaks kept, list items as "•" lines. `droppingQuotes` also leaves out quoted
    /// history (blockquotes, and the quote blocks of Gmail and other mail apps).
    static func plainText(fromHTML html: String, droppingQuotes: Bool = false) -> String {
        var reader = HTMLTextReader(html: html, droppingQuotes: droppingQuotes)
        return tidied(reader.read().components(separatedBy: "\n"))
    }

    private static let metaCharset = try! NSRegularExpression(
        pattern: #"<meta[^>]*?charset\s*=\s*["']?\s*([A-Za-z0-9_:.\-]+)"#, options: [.caseInsensitive])

    /// The charset a <meta> tag declares, for HTML sent without one in its Content-Type.
    static func declaredCharset(inHTML data: Data) -> String? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        let ns = head as NSString
        guard let m = metaCharset.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// format=flowed (RFC 3676): a line that ends in a space goes on in the next one.
    static func unflowed(_ text: String, deletingSpace: Bool) -> String {
        var lines: [String] = []
        var paragraph: (text: String, depth: Int)?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw[...]
            var depth = 0
            while line.first == ">" {
                depth += 1
                line = line.dropFirst()
            }
            if line.first == " " { line = line.dropFirst() } // space-stuffed
            let soft = line.last == " " && line != "-- "
            var piece = String(line)
            if soft, deletingSpace { piece.removeLast() }
            if let open = paragraph, open.depth == depth {
                paragraph = (open.text + piece, depth)
            } else {
                if let open = paragraph { lines.append(quotePrefix(open.depth) + open.text) }
                paragraph = (piece, depth)
            }
            if !soft, let done = paragraph {
                lines.append(quotePrefix(done.depth) + done.text)
                paragraph = nil
            }
        }
        if let open = paragraph { lines.append(quotePrefix(open.depth) + open.text) }
        return lines.joined(separator: "\n")
    }

    private static func quotePrefix(_ depth: Int) -> String {
        depth == 0 ? "" : String(repeating: ">", count: depth) + " "
    }

    /// Lines without trailing spaces, at most one blank line in a row and none at either end.
    static func tidied(_ lines: [String]) -> String {
        var out: [String] = []
        var blank = false
        for raw in lines {
            var line = raw
            while line.last?.isWhitespace == true { line.removeLast() }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blank = !out.isEmpty
                continue
            }
            if blank { out.append("") }
            blank = false
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Characters that take no space and only pad out newsletters' preview text.
    static let invisible: Set<UInt32> = [0xAD, 0x34F, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF]

    /// Non-breaking spaces as spaces, without soft hyphens and zero-width spaces.
    static func visible(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0xA0 }) else { return text }
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            switch s.value {
            case 0xA0, 0x2007, 0x202F: scalars.append(" ")
            // Joiners (0x200C, 0x200D) stay: emoji and some scripts need them.
            case 0xAD, 0x34F, 0x200B, 0x2060, 0xFEFF: continue
            default: scalars.append(s)
            }
        }
        return String(scalars)
    }
}

/// Reads HTML as text in one pass over its UTF-8 bytes (tags are ASCII; text passes through untouched).
private struct HTMLTextReader {
    private let bytes: [UInt8]
    private let droppingQuotes: Bool
    private var i = 0
    private var out = TextLines()
    /// Inside an element that isn't shown (hidden, or quoted history): its name and how deep.
    private var skipping: (name: String, depth: Int)?
    private var preformatted = 0
    /// Open lists, innermost last: nil for bullets, else the last number used.
    private var lists: [Int?] = []

    private static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                                                    "param", "source", "track", "wbr"]
    /// Never text on the page.
    private static let rawTextElements: Set<String> = ["script", "style", "title", "template", "xml"]
    private static let paragraphElements: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "table", "blockquote", "dl", "hr",
                                                         "figure", "address"]
    private static let lineElements: Set<String> = ["div", "section", "article", "header", "footer", "main", "nav", "aside", "tr",
                                                    "li", "dt", "dd", "figcaption", "form", "fieldset", "details", "summary",
                                                    "caption", "center", "legend"]
    /// Where Gmail, Yahoo, Thunderbird and Proton put quoted history (Outlook prefixes classes with "x_").
    private static let quoteClasses: Set<String> = ["gmail_quote", "gmail_quote_container", "x_gmail_quote", "yahoo_quoted",
                                                    "moz-cite-prefix", "protonmail_quote"]

    init(html: String, droppingQuotes: Bool) {
        bytes = Array(html.utf8)
        self.droppingQuotes = droppingQuotes
    }

    mutating func read() -> String {
        while i < bytes.count {
            if bytes[i] == Byte.lt { readTag() } else { readText() }
        }
        return out.text
    }

    private mutating func readText() {
        let start = i
        while i < bytes.count, bytes[i] != Byte.lt { i += 1 }
        guard skipping == nil else { return }
        out.add(String(decoding: bytes[start..<i], as: UTF8.self), preformatted: preformatted > 0)
    }

    private mutating func readTag() {
        let n = bytes.count
        if matches("<!--", at: i) {
            i = find("-->", from: i + 4).map { $0 + 3 } ?? n
            return
        }
        if i + 1 < n, bytes[i + 1] == Byte.bang || bytes[i + 1] == Byte.question {
            // <!DOCTYPE …>, <![CDATA[…]]>, <?xml …?>
            i = (bytes[(i + 1)...].firstIndex(of: Byte.gt) ?? n - 1) + 1
            return
        }
        var j = i + 1
        let closing = j < n && bytes[j] == Byte.slash
        if closing { j += 1 }
        let nameStart = j
        while j < n, Self.isNameByte(bytes[j]) { j += 1 }
        guard j > nameStart, Self.isLetter(bytes[nameStart]) else {
            // "1 < 2": just text.
            if skipping == nil { out.add("<", preformatted: preformatted > 0) }
            i += 1
            return
        }
        let name = String(decoding: bytes[nameStart..<j], as: UTF8.self).lowercased()
        let end = tagEnd(from: j)
        let attributes = bytes[j..<end]
        let selfClosing = end > j && bytes[end - 1] == Byte.slash
        i = min(end + 1, n)
        if closing { close(name) } else { open(name, attributes, selfClosing: selfClosing) }
    }

    private mutating func open(_ name: String, _ attributes: ArraySlice<UInt8>, selfClosing: Bool) {
        let isVoid = Self.voidElements.contains(name)
        if var skip = skipping {
            if name == skip.name, !isVoid, !selfClosing {
                skip.depth += 1
                skipping = skip
            }
            return
        }
        if Self.rawTextElements.contains(name) {
            if !selfClosing { i = afterClosingTag(name) }
            return
        }
        if !isVoid, !selfClosing, hides(name, attributes) {
            skipping = (name, 1)
            return
        }
        switch name {
        case "br":
            out.newLine()
        case "li":
            out.lineBreak(1)
            if let innermost = lists.last, let number = innermost {
                lists[lists.count - 1] = number + 1
                out.marker("\(number + 1).")
            } else {
                out.marker("•")
            }
        case "ul":
            lists.append(nil)
            out.lineBreak(lists.count > 1 ? 1 : 2)
        case "ol":
            let start = Self.attributes(attributes)["start"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
            lists.append(start - 1)
            out.lineBreak(lists.count > 1 ? 1 : 2)
        case "td", "th":
            out.addSpace()
        case "pre":
            preformatted += 1
            out.lineBreak(2)
        default:
            if Self.paragraphElements.contains(name) {
                out.lineBreak(2)
            } else if Self.lineElements.contains(name) {
                out.lineBreak(1)
            }
        }
    }

    private mutating func close(_ name: String) {
        if var skip = skipping {
            if name == skip.name {
                skip.depth -= 1
                skipping = skip.depth > 0 ? skip : nil
            }
            return
        }
        switch name {
        case "ul", "ol":
            if !lists.isEmpty { lists.removeLast() }
            out.lineBreak(lists.isEmpty ? 2 : 1)
        case "td", "th":
            out.addSpace()
        case "pre":
            preformatted = max(0, preformatted - 1)
            out.lineBreak(2)
        default:
            if Self.paragraphElements.contains(name) {
                out.lineBreak(2)
            } else if Self.lineElements.contains(name) {
                out.lineBreak(1)
            }
        }
    }

    /// Hidden (`hidden`, `display: none`), or quoted history when dropping it.
    private func hides(_ name: String, _ attributes: ArraySlice<UInt8>) -> Bool {
        if droppingQuotes, name == "blockquote" { return true }
        guard !attributes.isEmpty else { return false }
        let attrs = Self.attributes(attributes)
        if attrs["hidden"] != nil { return true }
        if let style = attrs["style"], style.lowercased().filter({ !$0.isWhitespace }).contains("display:none") { return true }
        guard droppingQuotes, let classes = attrs["class"]?.lowercased() else { return false }
        return classes.split(whereSeparator: \.isWhitespace).contains { Self.quoteClasses.contains(String($0)) }
    }

    /// Where the tag ends (its ">"), past quoted attribute values.
    private func tagEnd(from start: Int) -> Int {
        let n = bytes.count
        var k = start
        while k < n, bytes[k] != Byte.gt {
            guard bytes[k] == Byte.equals else {
                k += 1
                continue
            }
            k += 1
            while k < n, Self.isSpace(bytes[k]) { k += 1 }
            if k < n, bytes[k] == Byte.doubleQuote || bytes[k] == Byte.singleQuote {
                let quote = bytes[k]
                k += 1
                while k < n, bytes[k] != quote { k += 1 }
                if k < n { k += 1 }
            }
        }
        return k
    }

    /// Just past `</name…>`, or the end when it never closes.
    private func afterClosingTag(_ name: String) -> Int {
        let target = Array("</\(name)".utf8)
        let n = bytes.count
        var k = i
        while k + target.count <= n {
            if bytes[k] == Byte.lt, zip(bytes[k..<(k + target.count)], target).allSatisfy({ Self.lowercased($0) == $1 }) {
                let after = k + target.count
                if after == n || !Self.isNameByte(bytes[after]) {
                    return (bytes[after...].firstIndex(of: Byte.gt) ?? n - 1) + 1
                }
            }
            k += 1
        }
        return n
    }

    private func matches(_ text: String, at index: Int) -> Bool {
        let pattern = Array(text.utf8)
        return index + pattern.count <= bytes.count && bytes[index..<(index + pattern.count)].elementsEqual(pattern)
    }

    private func find(_ text: String, from start: Int) -> Int? {
        var k = start
        while k < bytes.count {
            if matches(text, at: k) { return k }
            k += 1
        }
        return nil
    }

    /// An element's attributes: lowercased names, entity-decoded values.
    static func attributes(_ bytes: ArraySlice<UInt8>) -> [String: String] {
        var result: [String: String] = [:]
        var k = bytes.startIndex
        let end = bytes.endIndex
        while k < end {
            while k < end, isSpace(bytes[k]) || bytes[k] == Byte.slash { k += 1 }
            let nameStart = k
            while k < end, !isSpace(bytes[k]), bytes[k] != Byte.equals, bytes[k] != Byte.slash { k += 1 }
            guard k > nameStart else {
                k += 1
                continue
            }
            let name = String(decoding: bytes[nameStart..<k], as: UTF8.self).lowercased()
            while k < end, isSpace(bytes[k]) { k += 1 }
            var value = ""
            if k < end, bytes[k] == Byte.equals {
                k += 1
                while k < end, isSpace(bytes[k]) { k += 1 }
                if k < end, bytes[k] == Byte.doubleQuote || bytes[k] == Byte.singleQuote {
                    let quote = bytes[k]
                    k += 1
                    let valueStart = k
                    while k < end, bytes[k] != quote { k += 1 }
                    value = String(decoding: bytes[valueStart..<k], as: UTF8.self)
                    if k < end { k += 1 }
                } else {
                    let valueStart = k
                    while k < end, !isSpace(bytes[k]) { k += 1 }
                    value = String(decoding: bytes[valueStart..<k], as: UTF8.self)
                }
            }
            if result[name] == nil { result[name] = MailText.decodeEntities(value) }
        }
        return result
    }

    private static func isLetter(_ c: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(c)
    }

    private static func isNameByte(_ c: UInt8) -> Bool {
        isLetter(c) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) || c == UInt8(ascii: "-") || c == UInt8(ascii: ":") || c == UInt8(ascii: "_")
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C
    }

    private static func lowercased(_ c: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(c) ? c + 32 : c
    }

    private enum Byte {
        static let lt = UInt8(ascii: "<")
        static let gt = UInt8(ascii: ">")
        static let slash = UInt8(ascii: "/")
        static let bang = UInt8(ascii: "!")
        static let question = UInt8(ascii: "?")
        static let equals = UInt8(ascii: "=")
        static let doubleQuote = UInt8(ascii: "\"")
        static let singleQuote = UInt8(ascii: "'")
    }
}

/// Text being put together from HTML: whitespace collapsed as a browser would, line and paragraph breaks
/// where blocks begin and end.
private struct TextLines {
    private(set) var text = ""
    private var breaks = 0
    private var pendingSpace = false
    /// Just wrote a list marker: breaks before the item's first words don't count.
    private var afterMarker = false

    mutating func lineBreak(_ count: Int) {
        guard !afterMarker else { return }
        breaks = max(breaks, count)
        pendingSpace = false
    }

    /// <br>: every one is a line of its own.
    mutating func newLine() {
        guard !afterMarker else { return }
        breaks = min(breaks + 1, 2)
        pendingSpace = false
    }

    mutating func addSpace() {
        pendingSpace = true
    }

    mutating func marker(_ marker: String) {
        write(Substring(marker))
        pendingSpace = true
        afterMarker = true
    }

    mutating func add(_ raw: String, preformatted: Bool) {
        let decoded = MailText.visible(MailText.decodeEntities(raw))
        if preformatted {
            guard !decoded.isEmpty else { return }
            flushBreaks()
            text += MailText.normalizedNewlines(decoded)
            afterMarker = false
            return
        }
        if decoded.first?.isWhitespace == true { pendingSpace = true }
        var first = true
        for word in decoded.split(whereSeparator: \.isWhitespace) {
            // Zero-width joiners on their own are newsletter padding.
            if word.unicodeScalars.allSatisfy({ MailText.invisible.contains($0.value) }) { continue }
            if !first { pendingSpace = true }
            write(word)
            first = false
        }
        if decoded.last?.isWhitespace == true { pendingSpace = true }
    }

    private mutating func write(_ word: Substring) {
        if breaks > 0 {
            flushBreaks()
        } else if pendingSpace, let last = text.last, !last.isWhitespace {
            text += " "
        }
        pendingSpace = false
        afterMarker = false
        text += word
    }

    private mutating func flushBreaks() {
        if breaks > 0, !text.isEmpty {
            while text.last == " " { text.removeLast() }
            text += String(repeating: "\n", count: breaks)
        }
        breaks = 0
    }
}

// MARK: - Quoted history

/// The new part of an email in a conversation: without the quoted history under "On … wrote:", an Outlook
/// "From: … Sent: …" block or "-----Original Message-----", and without lines quoted with ">". Answers
/// written between quoted lines stay. A forwarded message isn't quoted history and stays too.
enum MailQuote {
    static func trimmed(_ text: String) -> String {
        let lines = MailText.normalizedNewlines(text).components(separatedBy: "\n")
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        // From each line to the end: how many lines have text, and how many of those are quoted. (Counted
        // once, so a long email with many "wrote:" lines still takes one pass.)
        var textFrom = [Int](repeating: 0, count: lines.count + 1)
        var quotedFrom = [Int](repeating: 0, count: lines.count + 1)
        for k in lines.indices.reversed() {
            textFrom[k] = textFrom[k + 1] + (trimmedLines[k].isEmpty ? 0 : 1)
            quotedFrom[k] = quotedFrom[k + 1] + (isQuoted(trimmedLines[k]) ? 1 : 0)
        }
        var cut = lines.count
        var dropped = Set<Int>()
        var i = 0
        while i < lines.count {
            let line = trimmedLines[i]
            if line.isEmpty || isQuoted(line) {
                i += 1
                continue
            }
            if isOriginalMessageLine(line) || (startsHeaderBlock(at: i, in: lines) && !isForwarded(before: i, in: lines)) {
                cut = i
                break
            }
            // Outlook on the web: a line of underscores, then the header block.
            if line.count >= 10, line.allSatisfy({ $0 == "_" }), let next = nextTextLine(after: i, in: lines),
               startsHeaderBlock(at: next, in: lines) {
                cut = i
                break
            }
            if let attribution = attribution(at: i, in: lines) {
                let after = textFrom[attribution.last + 1], quoted = quotedFrom[attribution.last + 1]
                if quoted == after || (quoted == 0 && attribution.isStrong) {
                    cut = i
                    break
                }
                if quoted > 0 {
                    // Answers written between the quoted lines: keep them, without the "wrote:" line.
                    dropped.formUnion(i...attribution.last)
                    i = attribution.last + 1
                    continue
                }
            }
            i += 1
        }
        let kept = lines[..<cut].indices.filter { !dropped.contains($0) && !isQuoted(trimmedLines[$0]) }
        return MailText.tidied(kept.map { lines[$0] })
    }

    private static func isQuoted(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix(">")
    }

    /// "… wrote:" (and the same in other languages) ending a line.
    private static let wrote = try! NSRegularExpression(
        pattern: #"\b(wrote|a écrit|schrieb|escribió|escreveu|ha scritto|schreef|skrev|napisał|napsal|kirjoitti)\b[^:]{0,120}:\s*$"#,
        options: [.caseInsensitive])
    /// "On Mon, 5 Oct 2026 …" (and the same in other languages).
    private static let attributionStart = try! NSRegularExpression(pattern: #"^(On|Le|Am|El|Em|Il|Op|Den|W dniu|Dne)\s"#)

    /// "On Mon, 5 Oct 2026 at 10:42, Sam Lee <sam@…> wrote:", which mail apps wrap over up to three lines.
    /// Strong when it starts the way they write it; without that, only a short single line counts.
    private static func attribution(at start: Int, in lines: [String]) -> (last: Int, isStrong: Bool)? {
        var joined = ""
        for end in start..<min(start + 3, lines.count) {
            let line = lines[end].trimmingCharacters(in: .whitespaces)
            if end > start, line.isEmpty || isQuoted(line) { return nil }
            joined = joined.isEmpty ? line : joined + " " + line
            guard joined.count <= 400 else { return nil }
            let range = NSRange(location: 0, length: (joined as NSString).length)
            guard wrote.firstMatch(in: joined, range: range) != nil else { continue }
            let strong = attributionStart.firstMatch(in: joined, range: range) != nil
            return strong || (end == start && joined.count <= 200) ? (end, strong) : nil
        }
        return nil
    }

    private static let originalMessage = try! NSRegularExpression(
        pattern: #"^-{2,}\s*(original message|ursprüngliche nachricht|message d'origine|mensaje original|messaggio originale|oorspronkelijk bericht|mensagem original)\s*-{2,}$"#,
        options: [.caseInsensitive])

    private static func isOriginalMessageLine(_ line: String) -> Bool {
        originalMessage.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private enum Label { case from, date, to, subject }

    private static let labels: [Label: Set<String>] = [
        .from: ["from", "de", "von", "da", "van", "från", "fra", "od"],
        .date: ["sent", "date", "envoyé", "gesendet", "datum", "enviado", "fecha", "data", "verzonden", "skickat", "sendt", "wysłano", "inviato"],
        .to: ["to", "à", "a", "an", "para", "aan", "till", "til", "do"],
        .subject: ["subject", "objet", "betreff", "asunto", "assunto", "oggetto", "onderwerp", "ämne", "emne", "temat"],
    ]

    /// "From:", "*Sent:*", "Objet :": the label a header-block line starts with.
    private static func label(_ line: String) -> Label? {
        let text = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        guard let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 12 else { return nil }
        let name = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        return labels.first { $0.value.contains(name) }?.key
    }

    /// "From: …" followed closely by at least two of Sent/Date, To and Subject: Outlook's quoted original.
    private static func startsHeaderBlock(at index: Int, in lines: [String]) -> Bool {
        guard label(lines[index]) == .from else { return false }
        var seen = Set<Label>()
        for line in lines[(index + 1)..<min(index + 7, lines.count)] {
            if let found = label(line), found != .from { seen.insert(found) }
        }
        return seen.count >= 2
    }

    private static let forwardMarkers = ["forwarded message", "begin forwarded message", "weitergeleitete nachricht", "message transféré",
                                         "mensaje reenviado", "messaggio inoltrato"]

    /// A forward's marker in the three lines with text just above (within the 20 lines before).
    private static func isForwarded(before index: Int, in lines: [String]) -> Bool {
        lines[max(0, index - 20)..<index].reversed().lazy.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            .prefix(3)
            .contains { line in forwardMarkers.contains { line.contains($0) } }
    }

    /// The next line with text, within the 5 lines after.
    private static func nextTextLine(after index: Int, in lines: [String]) -> Int? {
        lines.indices.dropFirst(index + 1).prefix(5).first { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
