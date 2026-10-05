import Foundation

// The RFC 5322 reply Docket sends, or saves as a Gmail draft: From (the right one of your addresses), To and
// Cc (with the reply-all rules), a "Re:" subject (RFC 2047-encoded when it isn't ASCII), In-Reply-To and
// References, Date, a UTF-8 plain-text body in base64, and CRLF line endings. Gmail takes it as base64url
// `raw` with the conversation's threadId and adds the Message-ID itself.

/// One of your addresses in Gmail ("Send mail as"), and the name it sends with.
struct MailIdentity: Hashable, Sendable {
    var address: String
    var name: String?
    var isDefault = false
}

enum MailReplyBuilder {
    /// Who a reply goes to.
    struct Recipients: Hashable, Sendable {
        var to: [MailSender]
        var cc: [MailSender]
    }

    /// Reply: to the original's Reply-To, else its From; for a message you sent, to the people you sent it
    /// to (as Gmail does). Reply all: everyone else on its To and Cc as well. Never you (`fromAddress` or any
    /// of `ownAddresses`, however the address is written: see `mailbox`), and nobody twice. Only you to
    /// answer (a note to yourself, a Reply-To that's you): back to you. No address to answer at all: nobody,
    /// rather than someone else on the email the user didn't choose.
    static func recipients(for reply: MailReply, ownAddresses: Set<String> = []) -> Recipients {
        let me = Set(ownAddresses.union([reply.fromAddress]).map(mailbox))
        func isMe(_ sender: MailSender) -> Bool { me.contains(mailbox(sender.address ?? "")) }
        let headers = reply.headers
        let from = MailSender.list(headers.from)
        let replyTo = MailSender.list(headers.replyTo ?? "")
        let to = headers.to.flatMap(MailSender.list)
        let cc = headers.cc.flatMap(MailSender.list)
        let fromMe = !from.isEmpty && from.allSatisfy(isMe)
        let answer = fromMe ? to : (replyTo.isEmpty ? from : replyTo)
        var primary = answer
        var copies: [MailSender] = []
        if reply.replyAll {
            if !fromMe { primary += to }
            copies = cc
        }
        var seen = Set<String>()
        var toList = primary.filter { !isMe($0) && seen.insert(key($0)).inserted }
        var ccList = copies.filter { !isMe($0) && seen.insert(key($0)).inserted }
        if toList.isEmpty {
            toList = ccList
            ccList = []
        }
        if toList.isEmpty, let back = (fromMe ? from : answer).first { toList = [back] }
        return Recipients(to: toList, cc: ccList)
    }

    private static func key(_ sender: MailSender) -> String {
        (sender.address ?? "").lowercased()
    }

    /// The mailbox an address delivers to, to recognise your own addresses however they're written:
    /// lowercased, without a "+tag", and for Gmail without dots ("First.Last+deals@gmail.com" is
    /// firstlast@gmail.com).
    static func mailbox(_ address: String) -> String {
        let lower = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = lower.lastIndex(of: "@") else { return lower }
        var local = String(lower[..<at])
        var domain = String(lower[lower.index(after: at)...])
        if let plus = local.firstIndex(of: "+"), plus > local.startIndex { local = String(local[..<plus]) }
        if domain == "googlemail.com" { domain = "gmail.com" }
        if domain == "gmail.com" { local.removeAll { $0 == "." } }
        return local + "@" + domain
    }

    /// The address a reply goes from, as Gmail picks it: the one of yours the original came from or was sent
    /// to, else your default, else the connected address.
    static func identity(for reply: MailReply, among identities: [MailIdentity]) -> MailIdentity {
        var yours: [String: MailIdentity] = [:]
        for identity in identities where yours[mailbox(identity.address)] == nil {
            yours[mailbox(identity.address)] = identity
        }
        let headers = reply.headers
        let original = ([headers.from] + headers.to + headers.cc).flatMap(MailSender.list).map { mailbox($0.address ?? "") }
        if let match = original.lazy.compactMap({ yours[$0] }).first { return match }
        if let preferred = identities.first(where: \.isDefault) ?? yours[mailbox(reply.fromAddress)] { return preferred }
        return MailIdentity(address: reply.fromAddress)
    }

    /// "Re: Q3 numbers". A subject that already starts with "Re:" stays as it is.
    static func subject(replyingTo original: String) -> String {
        let subject = headerSafe(original)
        if subject.range(of: #"^re\s*(\[\d+\])?\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil { return subject }
        return subject.isEmpty ? "Re:" : "Re: \(subject)"
    }

    /// The whole message, ready to go to Gmail (as `MailBase64.urlSafe`).
    static func message(for reply: MailReply, from identity: MailIdentity? = nil, ownAddresses: Set<String> = [],
                        date: Date = Date(), timeZone: TimeZone = .current) -> Data {
        let sender = identity ?? MailIdentity(address: reply.fromAddress)
        let recipients = recipients(for: reply, ownAddresses: ownAddresses.union([sender.address]))
        var lines: [String] = []
        lines.append(folded("From", [address(MailSender(name: sender.name, address: sender.address)) ?? headerSafe(sender.address)]))
        lines.append(folded("To", recipients.to.compactMap(address)))
        if !recipients.cc.isEmpty { lines.append(folded("Cc", recipients.cc.compactMap(address))) }
        lines.append(subjectLine(subject(replyingTo: reply.headers.subject)))
        let parent = reply.headers.messageID.flatMap { messageIDs(in: $0).first }
        if let parent { lines.append("In-Reply-To: \(parent)") }
        let chain = references(reply.headers.references, parent: parent)
        if !chain.isEmpty { lines.append(folded("References", chain, separator: "")) }
        lines.append("Date: \(dateValue(date, timeZone: timeZone))")
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        // Text is CRLF on the wire (RFC 2046), and base64 lines are at most 76 characters.
        let text = MailText.normalizedNewlines(reply.body).replacingOccurrences(of: "\n", with: "\r\n")
        let body = Data(text.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n").utf8)
    }

    // MARK: Headers

    /// The original's References (or the In-Reply-To it stood for), then its Message-ID; at most 30, the
    /// first and the latest, as very long chains get turned away.
    static func references(_ references: String?, parent: String?) -> [String] {
        var ids: [String] = []
        for id in messageIDs(in: references ?? "") + [parent].compactMap({ $0 }) where !ids.contains(id) {
            ids.append(id)
        }
        return ids.count > 30 ? [ids[0]] + ids.suffix(29) : ids
    }

    private static let messageIDPattern = try! NSRegularExpression(pattern: #"<[^<>\s\p{Cc}]+>"#)

    /// The "<…@…>" ids in a Message-ID, In-Reply-To or References header.
    static func messageIDs(in header: String) -> [String] {
        let ns = header as NSString
        let ids = messageIDPattern.matches(in: header, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        if !ids.isEmpty { return ids }
        // Some mailers leave out the angle brackets.
        let bare = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = bare.contains("@") && !bare.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7F || $0 == "<" || $0 == ">" }
        return usable ? ["<\(bare)>"] : []
    }

    /// "Sam Lee <sam@…>" for a header: the name in quotes when it needs them, RFC 2047-encoded when it isn't
    /// ASCII. Nil without a usable address.
    static func address(_ sender: MailSender) -> String? {
        guard let address = sender.address.map(headerSafe), MailSender.isValidAddress(address) else { return nil }
        let name = headerSafe(sender.name ?? "")
        guard !name.isEmpty, name.lowercased() != address.lowercased() else { return address }
        let phrase = name.unicodeScalars.allSatisfy(\.isASCII) ? MailSender.quotedIfNeeded(name) : encodedWords(name).joined(separator: " ")
        return "\(phrase) <\(address)>"
    }

    private static func subjectLine(_ subject: String) -> String {
        guard subject.unicodeScalars.allSatisfy(\.isASCII) else {
            return "Subject: " + encodedWords(subject).joined(separator: "\r\n ")
        }
        return folded("Subject", subject.split(separator: " ").map(String.init), separator: "")
    }

    /// RFC 2047 "=?UTF-8?B?…?=" words, never splitting a character's bytes. Each is at most 68 characters,
    /// so even the first one fits on the "Subject: " line within 78.
    static func encodedWords(_ text: String) -> [String] {
        var words: [String] = []
        var chunk = Data()
        for scalar in text.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            // 42 bytes are 56 base64 characters, 68 with "=?UTF-8?B?" and "?=".
            if chunk.count + bytes.count > 42 {
                words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
        return words
    }

    /// "To: a, b, c", a long list going on in lines that start with a space, so each stays near 76 characters.
    static func folded(_ name: String, _ items: [String], separator: String = ",") -> String {
        var lines: [String] = []
        var line = "\(name):"
        for (index, item) in items.enumerated() {
            let piece = index < items.count - 1 ? item + separator : item
            if line.count + 1 + piece.count > 76, line != "\(name):" {
                lines.append(line)
                line = ""
            }
            line += " " + piece
        }
        lines.append(line)
        return lines.joined(separator: "\r\n")
    }

    /// One line, no control characters: nothing from the original can add a header of its own.
    static func headerSafe(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) }
        return SlackText.collapsed(String(scalars))
    }

    /// "Mon, 05 Oct 2026 10:42:00 -0700".
    static func dateValue(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

extension MailReplyHeaders {
    /// What a reply needs from the original's headers. References as RFC 5322 has it: the original's
    /// References, or else its In-Reply-To when that names one message.
    init(original headers: [MIMEHeader]) {
        func value(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        var references = MailReplyBuilder.messageIDs(in: value("References"))
        if references.isEmpty {
            let parent = MailReplyBuilder.messageIDs(in: value("In-Reply-To"))
            if parent.count == 1 { references = parent }
        }
        let replyTo = MailSender.list(value("Reply-To")).map(\.headerForm)
        self.init(messageID: MailReplyBuilder.messageIDs(in: value("Message-ID")).first,
                  references: references.isEmpty ? nil : references.joined(separator: " "),
                  subject: SlackText.collapsed(MailText.decodeEncodedWords(value("Subject"))),
                  from: MailSender.list(value("From")).first?.headerForm ?? SlackText.collapsed(MailText.decodeEncodedWords(value("From"))),
                  replyTo: replyTo.isEmpty ? nil : replyTo.joined(separator: ", "),
                  to: MailSender.list(value("To")).map(\.headerForm),
                  cc: MailSender.list(value("Cc")).map(\.headerForm))
    }
}
