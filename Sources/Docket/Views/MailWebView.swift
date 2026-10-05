import AppKit
import SwiftUI
import WebKit

// An email's HTML body in a sandboxed web view: no JavaScript, nothing loaded from the network, inline
// (cid:) images from the downloaded parts, links opened in the default browser, sized to its content.
//
// Remote loads are blocked twice over: a WKContentRuleList that blocks every http(s), ws(s), ftp and file
// load, and a Content-Security-Policy in the document that only allows data: images, fonts and media.
// Either one alone stops tracking pixels, remote images, stylesheets, fonts and frames. `<link>` hints
// (preconnect, DNS prefetch) aren't loads, so the email's `<link>` elements are made inert as well.

// MARK: - The document

/// Turns an email's HTML into the document Docket shows. Pure, so it's easy to test.
enum MailHTML {
    /// Nothing from the network; images, fonts and media only as data: URLs; inline styles; no forms,
    /// frames or base URL.
    static let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline' data:; font-src data:; "
        + "media-src data:; form-action 'none'; frame-src 'none'; child-src 'none'; base-uri 'none'"

    /// Inline images bigger than this stay in the attachment list rather than going into the page.
    static let maxInlineBytes = 8 * 1024 * 1024

    /// Standards mode, the security policy first (before anything that could load), light colours, and
    /// sizing rules so the page can be measured: an email that stretches itself to the window's height
    /// (`html, body { height: 100% }`, a `height="100%"` table) is measured by its content instead.
    static let head = "<!DOCTYPE html><meta charset=\"utf-8\">"
        + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"
        + "<meta http-equiv=\"x-dns-prefetch-control\" content=\"off\">"
        + "<meta name=\"color-scheme\" content=\"light\"><style>\(baseStyle)</style>"

    static let baseStyle = """
        html:root, html:root > body { height: auto !important; min-height: 0 !important; max-height: none !important; }
        html { background: #ffffff; color-scheme: light; -webkit-text-size-adjust: 100%; }
        body { margin: 16px; color: #1d1d1b; font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, sans-serif; overflow-wrap: break-word; }
        img { max-width: 100%; }
        img[src^="data:"] { height: auto; }
        pre { white-space: pre-wrap; }
        """

    /// The page to load: the email with its inline images in place and its `<link>`s inert, after Docket's
    /// own head. `inlineImages` maps Content-IDs (see `normalizedContentID`) to data: URLs.
    static func document(_ html: String, inlineImages: [String: String] = [:]) -> String {
        head + replacingContentIDs(in: inertLinks(html), with: inlineImages)
    }

    /// Whether there's anything in it but white space.
    static func hasContent(_ html: String) -> Bool {
        html.contains { !$0.isWhitespace }
    }

    /// Whether `word` (ASCII, lowercase, its first character not repeated in it) appears anywhere in any case:
    /// a quick look through the bytes before a slower search.
    static func mentions(_ html: String, _ word: String) -> Bool {
        let pattern = Array(word.utf8)
        guard let first = pattern.first else { return true }
        var matched = 0
        for byte in html.utf8 {
            // ASCII letters to lowercase; the other bytes in these words are the same either way.
            let lower = (65...90).contains(byte) ? byte | 0x20 : byte
            if lower == pattern[matched] {
                matched += 1
                if matched == pattern.count { return true }
            } else {
                matched = lower == first ? 1 : 0
            }
        }
        return false
    }

    /// `<link …>` as an inert `<meta …>` (void too, so the page's structure stays the same): a `<link>` can ask
    /// WebKit to connect to a server ahead of time, which tells the sender the email was opened.
    static func inertLinks(_ html: String) -> String {
        guard mentions(html, "<link") else { return html }
        let ns = html as NSString
        return linkTag.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: ns.length),
                                                withTemplate: "<meta data-docket-link")
    }

    private static let linkTag = try! NSRegularExpression(pattern: #"<link(?![\w-])"#, options: [.caseInsensitive])

    // The patterns below run on whatever an email contains, so none of them can backtrack its way into a
    // long stall: possessive quantifiers (`*+`, `?+`), and a bounded look inside a `<link>` tag.

    /// `src="cid:…"`, `background="cid:…"` and `url(cid:…)`: where an HTML email points at its own parts.
    private static let contentIDReference = try! NSRegularExpression(
        pattern: #"((?:\b(?:src|background)\s*+=\s*+["']?+\s*+)|(?:url\(\s*+["']?+\s*+))cid:([^"'\s)>]++)"#, options: [.caseInsensitive])

    /// "<Image001.PNG@01D9>" and "image001.png%4001D9" both become "image001.png@01d9".
    static func normalizedContentID(_ raw: String) -> String {
        let decoded = raw.removingPercentEncoding ?? raw
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "<>").union(.whitespacesAndNewlines)).lowercased()
    }

    /// The Content-IDs the HTML shows inline (normalized).
    static func referencedContentIDs(in html: String) -> Set<String> {
        guard mentions(html, "cid:") else { return [] }
        let ns = html as NSString
        return Set(contentIDReference.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { normalizedContentID(ns.substring(with: $0.range(at: 2))) }
            .filter { !$0.isEmpty })
    }

    /// Points every `cid:` reference that has a downloaded part at its data: URL; others are left alone
    /// (the security policy keeps them from loading).
    static func replacingContentIDs(in html: String, with images: [String: String]) -> String {
        guard !images.isEmpty, mentions(html, "cid:") else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in contentIDReference.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let image = images[normalizedContentID(ns.substring(with: m.range(at: 2)))] else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += ns.substring(with: m.range(at: 1)) + image
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// Pictures, stylesheets, fonts or frames from the internet: what the "Remote images are blocked" note is about.
    private static let remoteReference = try! NSRegularExpression(
        pattern: #"(?:\b(?:src|background|poster|srcset|data-src)\s*+=\s*+["']?+\s*+|url\(\s*+["']?+\s*+|@import\s++["']?+\s*+|<link\b[^>]{0,2000}?\bhref\s*+=\s*+["']?+\s*+)(?:https?:)?//"#,
        options: [.caseInsensitive])

    static func referencesRemoteContent(_ html: String) -> Bool {
        let ns = html as NSString
        return remoteReference.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// "data:image/png;base64,…". An odd MIME type becomes application/octet-stream.
    static func dataURL(_ data: Data, mimeType: String) -> String {
        let type = String(mimeType.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || "/+.-".contains($0)) })
        let safe = type.split(separator: "/").count == 2 ? type : "application/octet-stream"
        return "data:\(safe);base64,\(data.base64EncodedString())"
    }
}

/// What the message detail needs from an email's HTML, worked out once per email instead of on every
/// redraw (each keystroke in the notes or the reply below it redraws the detail).
@MainActor
final class MailHTMLFacts: ObservableObject {
    private var inline: (html: String, ids: Set<String>)?

    /// The Content-IDs the HTML shows inline (`MailHTML.referencedContentIDs`).
    func inlineContentIDs(_ html: String) -> Set<String> {
        if let inline, inline.html == html { return inline.ids }
        let ids = MailHTML.referencedContentIDs(in: html)
        inline = (html, ids)
        return ids
    }
}

// MARK: - Blocking the network

/// The content rule list every email page gets: no http(s), ws(s), ftp or file loads at all.
@MainActor
enum MailContentRules {
    static let identifier = "docket-mail-no-remote-loads"

    static let json = """
        [{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^file:"},"action":{"type":"block"}}]
        """

    private static var compiled: WKContentRuleList?
    private static var waiting: [CheckedContinuation<WKContentRuleList?, Never>]?

    /// Compiled once per launch. Nil only if WebKit couldn't compile it, and then no HTML is shown.
    static func ruleList() async -> WKContentRuleList? {
        if let compiled { return compiled }
        return await withCheckedContinuation { continuation in
            if waiting != nil {
                waiting?.append(continuation)
                return
            }
            waiting = [continuation]
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
                Task { @MainActor in
                    compiled = list
                    let ready = waiting ?? []
                    waiting = nil
                    for c in ready { c.resume(returning: list) }
                }
            }
        }
    }
}

// MARK: - The body view

/// An email's HTML on a white card, sized to its content (the detail scrolls, not the card). When the
/// height can't be read, it scrolls inside a fixed frame instead (at least 240 pt, at most 70% of the pane).
struct MailBodyView: View {
    let html: String
    /// Parts with a Content-ID: the inline images the HTML may show.
    let inlineParts: [MessageAttachment]
    /// Downloads a part once (cached) and gives its local file.
    let fetch: (MessageAttachment) async throws -> URL
    /// The detail pane's height, for the fallback frame.
    let paneHeight: CGFloat
    /// Shown instead of the card if WebKit can't block remote loads (it always can, but never risk it).
    let plainText: String

    @State private var rules: WKContentRuleList?
    @State private var document: String?
    /// The email asks for pictures or other things from the internet (which stay blocked).
    @State private var asksForRemote = false
    @State private var unavailable = false
    @State private var height: CGFloat?
    @State private var unmeasurable = false

    /// Taller than this and the page scrolls inside the card instead.
    private static let tallest: CGFloat = 30_000
    /// Inline images downloaded at the same time.
    private static let parallelImages = 4

    private struct Key: Hashable {
        var html: String
        var parts: [String]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if unavailable {
                Label("Docket couldn't show this email's formatting safely, so here it is as plain text.", systemImage: "doc.plaintext")
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink3)
                LinkedTextView(text: plainText)
            } else {
                card
                if asksForRemote {
                    Label("Remote images are blocked", systemImage: "eye.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.ink3)
                        .help("Docket never loads pictures or anything else from the internet in an email, so the sender can't tell when you read it.")
                }
            }
        }
        .task(id: Key(html: html, parts: inlineParts.map(\.id))) { await prepare() }
    }

    private var fallbackHeight: CGFloat { max(240, paneHeight * 0.7) }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        let measuring = height == nil && !unmeasurable
        return ZStack(alignment: .top) {
            if let rules, let document {
                MailWebView(html: document, rules: rules, sizedToContent: !unmeasurable, onMeasure: { measured in
                    guard let measured, measured <= Self.tallest else {
                        unmeasurable = true
                        return
                    }
                    if height == nil {
                        height = measured
                    } else if abs((height ?? 0) - measured) > 0.5 {
                        withAnimation(Motion.base) { height = measured }
                    }
                }, onGiveUp: {
                    // WebKit kept failing on this email: the text instead.
                    unavailable = true
                })
                .frame(height: unmeasurable ? fallbackHeight : (height ?? 1))
                .opacity(measuring ? 0 : 1)
            }
            if measuring {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Loading the email…").textStyle(.footnote).foregroundStyle(Color(nsColor: NSColor(hex: 0x5B5B56)))
                }
                .frame(maxWidth: .infinity, minHeight: 96)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: measuring ? 96 : nil)
        .background(shape.fill(Color.white))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.hair, lineWidth: 1))
        .environment(\.colorScheme, .light)
    }

    private func prepare() async {
        height = nil
        unmeasurable = false
        unavailable = false
        document = nil
        let html = html
        // A big email takes a moment to look through: off the main thread.
        let (referenced, remote) = await Task.detached(priority: .userInitiated) {
            (MailHTML.referencedContentIDs(in: html), MailHTML.referencesRemoteContent(html))
        }.value
        if Task.isCancelled { return }
        asksForRemote = remote
        guard let list = await MailContentRules.ruleList() else {
            unavailable = true
            return
        }
        rules = list
        // Download the inline images the HTML actually shows, a few at a time (each once; they're kept).
        let parts = inlineParts.filter { part in
            guard let id = part.contentID.map(MailHTML.normalizedContentID) else { return false }
            return referenced.contains(id) && (part.size ?? 0) <= MailHTML.maxInlineBytes
        }
        var files: [(id: String, mimeType: String, url: URL)] = []
        for start in stride(from: 0, to: parts.count, by: Self.parallelImages) {
            let batch = Array(parts[start..<min(start + Self.parallelImages, parts.count)])
            let downloads = batch.map { part in Task { try await fetch(part) } }
            for (part, download) in zip(batch, downloads) {
                guard let url = try? await download.value, let id = part.contentID.map(MailHTML.normalizedContentID) else { continue }
                files.append((id, part.mimeType, url))
            }
            if Task.isCancelled { return }
        }
        // Then in as data: URLs, the page put together off the main thread as well.
        let page = await Task.detached(priority: .userInitiated) { [files] () -> String in
            var images: [String: String] = [:]
            for file in files {
                guard let data = try? Data(contentsOf: file.url), data.count <= MailHTML.maxInlineBytes else { continue }
                images[file.id] = MailHTML.dataURL(data, mimeType: file.mimeType)
            }
            return MailHTML.document(html, inlineImages: images)
        }.value
        if Task.isCancelled { return }
        document = page
    }
}

// MARK: - The web view

/// WKWebView set up for email: JavaScript off, a throwaway data store, the rule list, no link previews
/// (they'd fetch the page), links opened in the default browser, no forms, no downloads, light appearance.
/// Reports the document's height in points (nil when it couldn't be read).
struct MailWebView: NSViewRepresentable {
    /// A page from `MailHTML.document`.
    let html: String
    let rules: WKContentRuleList
    /// Sized to its document, so the page around it scrolls; otherwise it scrolls itself.
    let sizedToContent: Bool
    let onMeasure: (CGFloat?) -> Void
    /// WebKit couldn't keep the page up (its process quit on it again after a reload).
    var onGiveUp: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MailWebKitView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.userContentController.add(rules)
        let view = MailWebKitView(frame: .zero, configuration: configuration)
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.appearance = NSAppearance(named: .aqua)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.forwardsScrolling = sizedToContent
        context.coordinator.onMeasure = onMeasure
        context.coordinator.onGiveUp = onGiveUp
        context.coordinator.attach(view)
        context.coordinator.load(html)
        return view
    }

    func updateNSView(_ view: MailWebKitView, context: Context) {
        context.coordinator.onMeasure = onMeasure
        context.coordinator.onGiveUp = onGiveUp
        view.forwardsScrolling = sizedToContent
        if context.coordinator.html != html { context.coordinator.load(html) }
    }

    static func dismantleNSView(_ view: MailWebKitView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private(set) var html: String?
        var onMeasure: (CGFloat?) -> Void = { _ in }
        var onGiveUp: () -> Void = {}
        private weak var view: MailWebKitView?
        /// When WebKit's process last quit while showing this email.
        private var lastCrash: Date?
        /// Bumped by every load and re-measure, so a late answer for an old one is ignored.
        private var pass = 0
        private var loaded = false
        private var pendingMeasure: DispatchWorkItem?

        /// Wide fixed-width mail (600 px newsletters) is zoomed out to fit, but never below this.
        static let minimumZoom: CGFloat = 0.5

        /// The page's width, the viewport's width and the height of its content, in CSS pixels. Runs in
        /// Docket's own script world: the page's JavaScript is off, this isn't the page's.
        static let sizeScript = """
            (function () {
              var root = document.documentElement;
              return [root.scrollWidth, window.innerWidth, Math.ceil(root.getBoundingClientRect().height)];
            })()
            """

        func attach(_ view: MailWebKitView) {
            self.view = view
            view.onWidthChange = { [weak self] in self?.widthChanged() }
        }

        func detach() {
            pendingMeasure?.cancel()
            view?.onWidthChange = nil
            view?.stopLoading()
            view?.navigationDelegate = nil
            view?.uiDelegate = nil
        }

        func load(_ html: String) {
            guard let view else { return }
            self.html = html
            pass += 1
            loaded = false
            view.pageZoom = 1
            view.loadHTMLString(html, baseURL: nil)
        }

        private func widthChanged() {
            guard loaded else { return }
            pendingMeasure?.cancel()
            // Once a resize settles: back to 100%, then fit again at the new width.
            let work = DispatchWorkItem { [weak self] in
                guard let self, let view = self.view else { return }
                self.pass += 1
                view.pageZoom = 1
                self.measure(self.pass, zoomed: false)
            }
            pendingMeasure = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        private func measure(_ pass: Int, zoomed: Bool) {
            guard let view, pass == self.pass else { return }
            view.evaluateJavaScript(Self.sizeScript, in: nil, in: .defaultClient) { [weak self] result in
                guard let self, pass == self.pass, let view = self.view else { return }
                guard case .success(let value) = result, let numbers = value as? [NSNumber], numbers.count == 3 else {
                    self.onMeasure(nil)
                    return
                }
                let contentWidth = CGFloat(numbers[0].doubleValue), viewport = CGFloat(numbers[1].doubleValue)
                let height = CGFloat(numbers[2].doubleValue)
                if !zoomed, viewport > 0, contentWidth > viewport + 1 {
                    // Too wide for the pane: zoom out until it fits (sideways scrolling covers the rest).
                    view.pageZoom = max(Self.minimumZoom, (viewport / contentWidth * 100).rounded(.down) / 100)
                    self.measure(pass, zoomed: true)
                    return
                }
                let points = (height * view.pageZoom).rounded(.up)
                self.onMeasure(points.isFinite && points > 0 ? points : nil)
            }
        }

        // MARK: Navigation: the document itself loads; a clicked link opens in the browser; nothing else goes anywhere.

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            if navigationAction.navigationType == .linkActivated {
                Self.openOutside(url)
                decisionHandler(.cancel)
            } else if url?.scheme?.lowercased() == "about" {
                decisionHandler(.allow)
            } else {
                // Form submissions, refreshes and redirects to the web, a data: page: never.
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.cancel(nil)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.cancel(nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            measure(pass, zoomed: false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onMeasure(nil)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onMeasure(nil)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Loaded again (macOS can end the process to free memory), but an email that brings WebKit down
            // again straight away isn't tried over and over.
            let now = Date()
            defer { lastCrash = now }
            guard let html, lastCrash.map({ now.timeIntervalSince($0) > 30 }) ?? true else {
                onGiveUp()
                return
            }
            load(html)
        }

        /// `target="_blank"` links: open in the browser, never in a new web view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated { Self.openOutside(navigationAction.request.url) }
            return nil
        }

        /// Web and mail links only.
        static func openOutside(_ url: URL?) {
            guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

/// The web view itself: hands vertical scrolling to the page around it while it's sized to its content,
/// says when its width changes (so the page is measured again), and trims WebKit's context menu.
final class MailWebKitView: WKWebView {
    var forwardsScrolling = true
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        // Sideways stays here, for mail that's still wider than the pane at the smallest zoom.
        if forwardsScrolling, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), let outer = enclosingScrollView {
            outer.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(newSize.width - lastWidth) > 0.5 else { return }
        lastWidth = newSize.width
        onWidthChange?()
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        MailWebMenu.tidy(menu)
    }
}

/// WebKit's context menu without the items that make no sense for an email (or that would fetch from
/// the network): reload, back and forward, downloads, opening in new windows, the inspector.
enum MailWebMenu {
    static let unwanted: Set<String> = [
        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierOpenMediaInNewWindow", "WKMenuItemIdentifierDownloadMedia",
        "WKMenuItemIdentifierOpenFrameInNewWindow", "WKMenuItemIdentifierInspectElement",
    ]

    static func tidy(_ menu: NSMenu) {
        for item in menu.items where unwanted.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        // No separator first, last, or twice in a row.
        var afterSeparator = true
        for item in menu.items {
            if item.isSeparatorItem {
                if afterSeparator { menu.removeItem(item) } else { afterSeparator = true }
            } else {
                afterSeparator = false
            }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}

// MARK: - Plain text with links

/// Plain text (an email's text part, a message in a thread) with its web and mail addresses clickable,
/// selectable for copying.
struct LinkedTextView: View, Equatable {
    let text: String
    var size: CGFloat = 15
    var color: Color = .bodyText

    var body: some View {
        Text(LinkedText.attributed(text))
            .font(.system(size: size))
            .foregroundStyle(color)
            .lineSpacing(3)
            .tint(Color.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .safeLinks()
    }
}

enum LinkedText {
    /// Long enough for any real email; past this, links aren't looked for (it would only be slow).
    static let scanLimit = 200_000
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The text with http(s) and mailto links marked (underlined).
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector, text.utf16.count <= scanLimit else { return result }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme),
                  let range = Range(match.range, in: text), let linked = Range(range, in: result) else { continue }
            result[linked].link = url
            result[linked].underlineStyle = .single
        }
        return result
    }
}

extension View {
    /// Links in message text open in the default browser or mail app; any other kind of link does nothing.
    func safeLinks() -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
}
