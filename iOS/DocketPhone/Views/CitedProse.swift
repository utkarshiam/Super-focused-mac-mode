import MemoryKit
import SwiftUI

/// Markdown-light prose from the brain ("**bold**", "- " bullets) with tappable [n] citations: [n] opens
/// `sources[n-1]`. Markers without a source are dropped.
struct CitedProse: View {
    let text: String
    let sources: [UUID]
    var size: CGFloat = 16
    var color: Color = .bodyText
    /// Show at most this many paragraphs or bullets (nil: all).
    var maxBlocks: Int?
    /// Line limit per paragraph or bullet (nil: none).
    var lineLimit: Int?
    @Environment(\.memoryPush) private var push

    private struct Block: Identifiable {
        var id: Int
        var text: String
        var bullet: Bool
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(Block(id: out.count, text: paragraph.joined(separator: " "), bullet: false)) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") {
                flush()
                out.append(Block(id: out.count, text: String(line.dropFirst(2)), bullet: true))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        if let maxBlocks { return Array(out.prefix(maxBlocks)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size >= 16 ? 10 : 7) {
            ForEach(blocks) { block in
                if block.bullet {
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Circle().fill(Color.ink3).frame(width: 4.5, height: 4.5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + size * 0.28 }
                        line(block.text)
                    }
                } else {
                    line(block.text)
                }
            }
        }
        .tint(Color.ink2)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "docket-cite", let n = Int(url.host() ?? ""), n >= 1, n <= sources.count else { return .discarded }
            Haptics.tap()
            push(.item(sources[n - 1]))
            return .handled
        })
    }

    private func line(_ s: String) -> some View {
        Text(Self.attributed(s, sourceCount: sources.count, size: size))
            .foregroundStyle(color)
            .lineSpacing(size >= 16 ? 3 : 2)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ s: String, sourceCount: Int, size: CGFloat) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            var a = AttributedString(buffer)
            a.font = .system(size: size, weight: bold ? .semibold : .regular)
            out += a
            buffer = ""
        }
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("**") {
                flush()
                bold.toggle()
                i = s.index(i, offsetBy: 2)
                continue
            }
            if s[i] == "[", let close = s[i...].firstIndex(of: "]"), let n = Int(s[s.index(after: i)..<close]) {
                flush()
                if n >= 1 && n <= sourceCount {
                    var a = AttributedString("[\(n)]")
                    a.font = .system(size: size * 0.8, weight: .semibold).monospacedDigit()
                    a.link = URL(string: "docket-cite://\(n)")
                    out += a
                } else if buffer.isEmpty, out.characters.last == " " {
                    // A dropped marker: don't leave a double space.
                    out.characters.removeLast()
                }
                i = s.index(after: close)
                continue
            }
            buffer.append(s[i])
            i = s.index(after: i)
        }
        flush()
        return out
    }
}
