import Foundation

/// Builds the `MemoryItem.sourceRef` strings that tie a memory to where it came from. The same source
/// always gives the same string, so `MemoryLibrary.upsert` updates instead of duplicating.
///
/// Shapes: `note:<uuid>`, `task:<uuid>`, `slack:<channel>:<ts>`, `gmail:<threadId>`, `engram:<id>`,
/// `url:<normalized url>`, `phone:<envelope uuid>`, `inbox:<file name>`.
public enum SourceRef {
    public static func note(_ id: UUID) -> String { "note:\(id.uuidString)" }
    public static func task(_ id: UUID) -> String { "task:\(id.uuidString)" }
    public static func slack(channel: String, ts: String) -> String { "slack:\(channel):\(ts)" }
    public static func gmail(threadID: String) -> String { "gmail:\(threadID)" }
    public static func engram(_ id: String) -> String { "engram:\(id)" }
    public static func phone(_ envelopeID: UUID) -> String { "phone:\(envelopeID.uuidString)" }
    public static func inbox(fileName: String) -> String { "inbox:\(fileName)" }

    /// `url:` + the normalized address, or nil when it isn't a web address.
    public static func url(_ address: String) -> String? {
        normalizedURL(address).map { "url:\($0)" }
    }

    /// The scheme ("note", "slack", "url"…) of a ref.
    public static func scheme(of ref: String) -> String? {
        ref.split(separator: ":", maxSplits: 1).first.map(String.init)
    }

    /// The same page written different ways comes out the same: no scheme, lowercase host without
    /// "www.", no fragment, no tracking parameters (utm_*, fbclid, gclid, mc_*, ref), no trailing slash.
    /// "https://www.Example.com/a/?utm_source=x#top" → "example.com/a".
    public static func normalizedURL(_ address: String) -> String? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = parts.host?.lowercased(), host.contains(".") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        parts.fragment = nil
        let kept = (parts.queryItems ?? []).filter { item in
            let name = item.name.lowercased()
            return !(name.hasPrefix("utm_") || name.hasPrefix("mc_") || ["fbclid", "gclid", "ref", "ref_src", "igshid", "si"].contains(name))
        }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        var out = host
        if let port = parts.port, port != 80, port != 443 { out += ":\(port)" }
        out += path
        if !kept.isEmpty {
            parts.queryItems = kept
            if let query = parts.percentEncodedQuery { out += "?" + query }
        }
        return out
    }
}
