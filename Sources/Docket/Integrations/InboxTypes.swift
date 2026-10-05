import Foundation

// The complete messages behind the Slack and Email tabs: their text, attachments, the whole thread or
// conversation around them, and what a reply needs. Shared by the Gmail and Slack clients, Integrations, AI
// and the views.

// MARK: - Content

/// A file attached to a Slack message or an email (metadata only; bytes are fetched on demand).
struct MessageAttachment: Identifiable, Codable, Hashable, Sendable {
    enum Remote: Codable, Hashable, Sendable {
        case slack(url: URL, thumbnail: URL?)          // url_private_download, thumb_360/480
        case gmail(messageID: String, attachmentID: String)
    }
    var id: String                // Slack file id ("F07…") or "<gmail message id>/<attachment id>"
    var name: String
    var mimeType: String
    var size: Int?
    var remote: Remote
    /// Inline in an HTML email (the part's Content-ID without <>): shown in the body, not the file list.
    var contentID: String?
    var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }
}

/// The complete message behind an inbox item.
struct MessageContent: Codable, Hashable, Sendable {
    /// Readable plain text: Slack markup resolved, or the email's text part (or text taken from its HTML).
    var text: String
    /// Slack mrkdwn as sent (for rich rendering); nil for email.
    var markup: String?
    /// The email's HTML body, when there is one.
    var html: String?
    var to: [String] = []
    var cc: [String] = []
    var attachments: [MessageAttachment] = []
    var fetchedAt: Date
}

/// One earlier message in the same Slack thread or email conversation.
struct ThreadMessage: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var from: String
    var date: Date
    var text: String
    var isMine: Bool
}

// MARK: - Whole threads

/// One message of a Gmail conversation, as the conversation view shows it.
struct ThreadEmail: Identifiable, Hashable, Sendable {
    var id: String                // the Gmail message id
    var from: String
    var date: Date
    var content: MessageContent
    /// What a reply to this message needs: its Message-ID and References, its sender and recipients.
    var replyHeaders: MailReplyHeaders
    /// Sent by the connected account: shown as "You".
    var isMine: Bool
    /// Gmail's STARRED label.
    var isStarred: Bool
    var snippet: String
}

/// One message of a Slack thread (the parent or a reply), as the thread view shows it.
struct ThreadSlackMessage: Identifiable, Hashable, Sendable {
    var id: String                // the message's ts ("1712345678.000100")
    var from: String
    var userID: String?
    var date: Date
    /// Slack mrkdwn as sent, for rich rendering; `text` is the same as plain words.
    var markup: String
    var text: String
    var files: [MessageAttachment]
    /// Posted by the connected account: shown as "You".
    var isMine: Bool
}

/// The whole Slack thread or email conversation an inbox item belongs to, oldest first, and which of its
/// messages is the item itself (`highlighted`, an index into the messages). A Slack message outside a thread
/// is a conversation of one.
enum InboxThread: Hashable, Sendable {
    case slack([ThreadSlackMessage], highlighted: Int)
    case email([ThreadEmail], highlighted: Int)
}

// MARK: - Replies

enum ReplyTone: String, Codable, CaseIterable, Identifiable, Sendable {
    case brief, friendly, formal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .brief: "Brief"
        case .friendly: "Friendly"
        case .formal: "Formal"
        }
    }
}

/// What a reply email needs from the original.
struct MailReplyHeaders: Codable, Hashable, Sendable {
    var messageID: String?        // the original's Message-ID header, with <>
    var references: String?
    var subject: String           // original subject, decoded
    var from: String              // original From (display form, "Sam Lee <sam@northwind.example>")
    var replyTo: String?
    var to: [String] = []
    var cc: [String] = []
}

struct MailReply: Hashable, Sendable {
    var threadID: String
    var headers: MailReplyHeaders
    /// The connected account's address (never in the To/Cc of a reply-all).
    var fromAddress: String
    var body: String
    var replyAll: Bool
}

/// The whole email as fetched with format=full.
struct GmailFullMessage: Hashable, Sendable {
    var id: String
    var threadID: String
    var content: MessageContent
    var replyHeaders: MailReplyHeaders
}

// MARK: - Reading saved copies

// Message content is kept in integrations.json. Like every saved model, it decodes leniently: a missing
// key falls back to a default, and one unreadable attachment doesn't cost the rest of the message.

extension MessageAttachment {
    private enum Keys: String, CodingKey { case id, name, mimeType, size, remote, contentID }

    // In an extension so the memberwise initializer stays available. Only the id and where to fetch the
    // file from are required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        remote = try c.decode(Remote.self, forKey: .remote)
        name = c.value(.name, default: "Attachment")
        mimeType = c.value(.mimeType, default: "application/octet-stream")
        size = c.value(.size, default: nil)
        contentID = c.value(.contentID, default: nil)
    }
}

extension MessageContent {
    private enum Keys: String, CodingKey { case text, markup, html, to, cc, attachments, fetchedAt }

    // In an extension so the memberwise initializer stays available.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        text = c.value(.text, default: "")
        markup = c.value(.markup, default: nil)
        html = c.value(.html, default: nil)
        to = c.value(.to, default: [])
        cc = c.value(.cc, default: [])
        attachments = c.value(.attachments, default: [LenientAttachment]()).compactMap(\.value)
        fetchedAt = c.value(.fetchedAt, default: .distantPast)
    }
}

private struct LenientAttachment: Decodable {
    let value: MessageAttachment?
    init(from decoder: Decoder) throws { value = try? MessageAttachment(from: decoder) }
}
