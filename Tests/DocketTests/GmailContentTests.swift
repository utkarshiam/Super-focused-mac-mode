import XCTest
@testable import Docket

// Complete emails without the network: MIME fixtures, text from HTML, quoted history, the reply Docket
// sends, and the Gmail client against a fake server (`FakeIntegrationServer`, in IntegrationsTests.swift).
// Made-up people and companies only.

// MARK: - Fixtures

private enum Mail {
    /// A raw message: header lines, an empty line, then the body, all with CRLF.
    static func raw(_ headers: [String], _ body: String) -> Data {
        Data((headers + ["", body]).joined(separator: "\r\n").utf8)
    }

    static func raw(_ headers: [String], bytes body: [UInt8]) -> Data {
        Data((headers + ["", ""]).joined(separator: "\r\n").utf8) + Data(body)
    }

    static func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
    static func base64URL(_ text: String) -> String { MailBase64.urlSafe(Data(text.utf8)) }

    static let maya = "maya@acme.example"

    static func session(_ server: FakeIntegrationServer, scopes: Set<String> = [GoogleOAuth.gmailScope]) -> GoogleSession {
        GoogleSession(client: .init(id: "1234-test.apps.googleusercontent.com", secret: "test-client-secret"), refreshToken: "1//refresh",
                      transport: server.transport,
                      tokens: .init(accessToken: "ya29.first", expiresAt: Date().addingTimeInterval(3000), refreshToken: nil, scopes: scopes))
    }

    static func client(_ server: FakeIntegrationServer) -> GmailClient {
        GmailClient(session: session(server, scopes: [GoogleOAuth.gmailScope, GoogleOAuth.composeScope]), transport: server.transport)
    }

    /// The header lines of a part in Gmail's format=full JSON.
    static func headers(_ pairs: [(String, String)]) -> String {
        "[" + pairs.map { #"{"name":\#(json($0.0)),"value":\#(json($0.1))}"# }.joined(separator: ",") + "]"
    }

    static func json(_ text: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    /// One message as Gmail's format=full returns it, with a plain-text body (or a payload of your own).
    static func message(_ id: String, thread: String = "t1", labels: [String] = ["INBOX"], from: String, date: Date,
                        subject: String = "Q3 numbers", text: String? = nil, payload: String? = nil, snippet: String = "") -> String {
        let top = headers([("From", from), ("To", "Maya Chen <maya@acme.example>"), ("Subject", subject),
                           ("Message-ID", "<\(id)@mail.example>"), ("Date", "Mon, 5 Oct 2026 09:12:00 -0700")])
        let body = payload ?? """
            {"partId":"","mimeType":"text/plain","filename":"","headers":\(top),"body":{"size":\((text ?? "").utf8.count),"data":"\(base64URL(text ?? ""))"}}
            """
        let labelList = labels.map(json).joined(separator: ",")
        return """
            {"id":"\(id)","threadId":"\(thread)","labelIds":[\(labelList)],"snippet":\(json(snippet)),
             "internalDate":"\(Int64(date.timeIntervalSince1970 * 1000))","payload":\(body)}
            """
    }
}

// MARK: - MIME

final class MailMIMETests: XCTestCase {
    func testNestedMultipartsAndTransferEncodings() throws {
        let html = #"<html><body><p>Numbers below.</p><img src="cid:chart@northwind.example" alt="Chart"></body></html>"#
        let raw = Mail.raw([
            #"From: "Lee, Sam" <sam.lee@northwind.example>"#,
            "To: Maya Chen <maya@acme.example>, =?UTF-8?B?\(Mail.base64("André Dubois"))?= <andre@fabrikam.example>",
            "Subject: =?UTF-8?Q?Q3_numbers_=E2=80=94_final?=",
            "Message-ID: <q3.final@northwind.example>",
            "MIME-Version: 1.0",
            #"Content-Type: multipart/mixed;"#,
            "\tboundary=\"outer\"", // folded onto a line that starts with a tab
        ], """
            This is a multi-part message in MIME format.
            --outer
            Content-Type: multipart/alternative; boundary=inner

            --inner
            Content-Type: text/plain; charset="UTF-8"
            Content-Transfer-Encoding: quoted-printable

            Hi Maya,=0A
            The numbers are attached. Caf=C3=A9 at 10=3A30? This line is long and wr=
            aps here.

            --inner
            Content-Type: multipart/related; boundary="rel"

            --rel
            Content-Type: text/html; charset=UTF-8
            Content-Transfer-Encoding: base64

            \(Data(html.utf8).base64EncodedString(options: [.lineLength64Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
            --rel
            Content-Type: image/png
            Content-Transfer-Encoding: base64
            Content-ID: <chart@northwind.example>
            Content-Disposition: inline; filename="chart.png"

            iVBORw0KGgo=
            --rel--
            --inner--
            --outer
            Content-Type: application/pdf; name="q3.pdf"
            Content-Disposition: attachment; filename*=UTF-8''Q3%20numbers%20%E2%80%94%20final.pdf
            Content-Transfer-Encoding: base64

            JVBERi0xLjQK
            --outer
            Content-Type: text/plain; charset=us-ascii
            Content-Transfer-Encoding: 7bit

            --\u{20}
            Sent from a phone
            --outer--
            The epilogue is ignored.
            """.replacingOccurrences(of: "\n", with: "\r\n"))

        let root = MailMIME.parse(raw)
        XCTAssertEqual(root.mimeType, "multipart/mixed")
        XCTAssertEqual(root.parts.map(\.mimeType), ["multipart/alternative", "application/pdf", "text/plain"])
        XCTAssertEqual(root.parts[0].parts.map(\.mimeType), ["text/plain", "multipart/related"])
        XCTAssertEqual(root.parts[0].parts[1].parts.map(\.mimeType), ["text/html", "image/png"])

        let body = MailBody(root)
        XCTAssertEqual(body.text, "Hi Maya,\n\nThe numbers are attached. Café at 10:30? This line is long and wraps here.\n\n-- \nSent from a phone")
        XCTAssertEqual(body.html, html, "base64 split over lines")
        XCTAssertEqual(body.files.map(\.name), ["chart.png", "Q3 numbers — final.pdf"])
        XCTAssertEqual(body.files.map(\.mimeType), ["image/png", "application/pdf"])
        XCTAssertEqual(body.files[0].contentID, "chart@northwind.example", "the HTML shows it")
        XCTAssertNil(body.files[1].contentID)
        XCTAssertEqual(body.files[0].data, Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertEqual(body.files[1].data, Data("%PDF-1.4\n".utf8))
        XCTAssertEqual(body.files[1].size, 9)

        let headers = MailReplyHeaders(original: root.headers)
        XCTAssertEqual(headers.subject, "Q3 numbers — final")
        XCTAssertEqual(headers.from, #""Lee, Sam" <sam.lee@northwind.example>"#)
        XCTAssertEqual(headers.to, ["Maya Chen <maya@acme.example>", "André Dubois <andre@fabrikam.example>"])
        XCTAssertEqual(headers.messageID, "<q3.final@northwind.example>")
        XCTAssertNil(headers.references)
    }

    func testTransferEncodingsByThemselves() {
        // base64: line breaks, stray characters and missing padding are fine.
        XCTAssertEqual(MailMIME.decode(Array("SGVs\r\nbG8=".utf8), transferEncoding: "base64"), Data("Hello".utf8))
        XCTAssertEqual(MailMIME.decode(Array("SGVsbG8".utf8), transferEncoding: " BASE64 "), Data("Hello".utf8))
        XCTAssertEqual(MailMIME.decode(Array("SGVs*bG8=".utf8), transferEncoding: "base64"), Data("Hello".utf8))
        // quoted-printable: escapes (either case), soft breaks, spaces added at line ends, stray "=" kept.
        XCTAssertEqual(MailMIME.decode(Array("a=3Db=\r\nc  \r\nd=e=XYz =c3=a9".utf8), transferEncoding: "quoted-printable"),
                       Data("a=bc\r\nd=e=XYz é".utf8))
        XCTAssertEqual(MailMIME.decode(Array("soft=  \nbreak".utf8), transferEncoding: "quoted-printable"), Data("softbreak".utf8))
        // 7bit, 8bit and binary are the bytes as they are.
        for encoding in ["7bit", "8bit", "binary", nil] {
            XCTAssertEqual(MailMIME.decode(Array("Grüße =3D".utf8), transferEncoding: encoding), Data("Grüße =3D".utf8))
        }
    }

    func testCharsets() {
        func text(_ contentType: String, _ bytes: [UInt8], encoding: String = "8bit") -> String {
            MailBody(MailMIME.parse(Mail.raw(["Content-Type: \(contentType)", "Content-Transfer-Encoding: \(encoding)"], bytes: bytes))).readableText
        }
        XCTAssertEqual(text("text/plain; charset=utf-8", Array("Grüße aus Köln".utf8)), "Grüße aus Köln")
        XCTAssertEqual(text("text/plain; charset=ISO-8859-1", [0x63, 0x61, 0x66, 0xE9]), "café")
        XCTAssertEqual(text("text/plain; charset=windows-1252", [0x93, 0x51, 0x33, 0x94, 0x20, 0x80, 0x35]), "“Q3” €5")
        XCTAssertEqual(text("text/plain; charset=us-ascii", Array("Plain".utf8), encoding: "7bit"), "Plain")
        XCTAssertEqual(text("text/plain; charset=koi8-r", [0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4]), "Привет", "any charset Foundation knows")
        XCTAssertEqual(text("text/plain; charset=\"x-made-up\"", Array("Olá".utf8) + [0xFF]), "Olá\u{FFFD}", "unknown: lossy UTF-8")
        XCTAssertEqual(text("text/plain; charset=iso-8859-1", Array("Café".utf8)), "Café", "UTF-8 labelled Latin-1 reads as UTF-8")
        XCTAssertEqual(text("text/plain", [0x63, 0x61, 0x66, 0xE9]), "café", "no charset and not UTF-8: Windows-1252")
        XCTAssertEqual(text("text/html", Array(#"<meta charset="windows-1252"><p>It"#.utf8) + [0x92] + Array("s here</p>".utf8)),
                       "It’s here", "HTML's own <meta> charset")
        XCTAssertEqual(text("text/plain; charset=utf-8", [0xEF, 0xBB, 0xBF] + Array("No BOM".utf8)), "No BOM")
        XCTAssertEqual(text("text/plain; charset=utf-8", Array("=E2=82=AC 5".utf8), encoding: "quoted-printable"), "€ 5")

        // Encoded words in a row are read together: some mailers split a character's bytes between two.
        XCTAssertEqual(MailText.decodeEncodedWords("=?UTF-8?Q?Caf=C3?= =?UTF-8?Q?=A9_au_lait?="), "Café au lait")
        XCTAssertEqual(MailText.decodeEncodedWords("=?UTF-8?B?\(Data([0xE2, 0x82]).base64EncodedString())?=\r\n =?utf-8?B?\(Data([0xAC]).base64EncodedString())?= 5"),
                       "€ 5")
        XCTAssertEqual(MailText.decodeEncodedWords("=?ISO-8859-1?Q?Andr=E9?= =?UTF-8?Q?_=C3=A9?= and =?UTF-8?Q?more?="), "André é and more",
                       "a new charset starts a new word; text between words stays")
    }

    func testFileNames() {
        func file(_ headers: [String], body: String = "SGVsbG8=") -> MailBody.File? {
            MailBody(MailMIME.parse(Mail.raw(headers + ["Content-Transfer-Encoding: base64"], body))).files.first
        }
        XCTAssertEqual(file(["Content-Type: application/pdf", #"Content-Disposition: attachment; filename="Board deck.pdf""#])?.name, "Board deck.pdf")
        XCTAssertEqual(file(["Content-Type: text/plain", "Content-Disposition: attachment; filename*=iso-8859-1'fr'r%E9sum%E9.txt"])?.name,
                       "résumé.txt", "RFC 2231 with a charset and a language")
        XCTAssertEqual(file(["Content-Type: application/vnd.ms-excel",
                             #"Content-Disposition: attachment; filename*0*=UTF-8''Q3%20; filename*1="numbers"; filename*2*=%20%E2%80%94%20final.xlsx"#])?.name,
                       "Q3 numbers — final.xlsx", "RFC 2231 continuations")
        XCTAssertEqual(file(["Content-Type: image/png", "Content-Disposition: inline; filename=\"=?UTF-8?B?\(Mail.base64("Équipe.png"))?=\""])?.name,
                       "Équipe.png", "an encoded word, as many mailers send")
        XCTAssertEqual(file([#"Content-Type: application/vnd.ms-excel; name="budget.xls""#])?.name, "budget.xls", "Content-Type's name")
        XCTAssertEqual(file([#"Content-Type: application/octet-stream; name="Q3 \"final\".pdf""#])?.name, #"Q3 "final".pdf"#)
        XCTAssertEqual(file([#"Content-Type: application/octet-stream; name="Q3 \"final\".pdf""#])?.mimeType, "application/pdf",
                       "octet-stream says nothing; the name does")

        let nameless = file(["Content-Type: image/jpeg"])
        XCTAssertEqual(nameless?.name, "Image.jpeg")
        XCTAssertEqual(file(["Content-Type: application/pdf", "Content-Disposition: attachment"])?.name, "Attachment.pdf")
        XCTAssertEqual(file(["Content-Type: text/calendar; method=REQUEST"])?.name, "Invite.ics")

        let sneaky = file(["Content-Type: application/octet-stream", #"Content-Disposition: attachment; filename="../../.ssh/config""#])
        XCTAssertEqual(sneaky?.name, "-..-.ssh-config", "no folders, not hidden")
        XCTAssertNil(file(["Content-Type: application/pdf", "Content-Disposition: attachment; filename=empty.pdf"], body: ""), "empty: no file")
        XCTAssertNil(file(["Content-Type: application/pkcs7-signature; name=smime.p7s"]), "a signature isn't a file anyone opens")
    }

    func testInlineImagesOnlyWhenTheHTMLShowsThem() {
        let raw = Mail.raw([#"Content-Type: multipart/related; boundary="b""#], """
            --b
            Content-Type: text/html; charset=utf-8

            <p>Logo: <img src="cid:Logo%40Acme.example"></p><div style="background: url('cid:bg@acme.example')"></div>
            --b
            Content-Type: image/png
            Content-ID: <logo@acme.example>
            Content-Transfer-Encoding: base64

            iVBORw0KGgo=
            --b
            Content-Type: image/gif
            Content-ID: <bg@acme.example>
            Content-Transfer-Encoding: base64

            R0lGODlh
            --b
            Content-Type: image/png
            Content-ID: <unused@acme.example>
            Content-Disposition: inline; filename="photo.png"
            Content-Transfer-Encoding: base64

            iVBORw0KGgo=
            --b--
            """.replacingOccurrences(of: "\n", with: "\r\n"))
        let files = MailBody(MailMIME.parse(raw)).files
        XCTAssertEqual(files.map(\.contentID), ["logo@acme.example", "bg@acme.example", nil])
        XCTAssertEqual(files.map(\.name), ["Image.png", "Image.gif", "photo.png"])
    }

    func testTextFromHTMLWhenThereIsNoTextPart() {
        let html = """
            <!DOCTYPE html><html><head><title>Ignore me</title><style>p { color: red; }</style>
            <script>document.write("no")</script></head>
            <body><div style="display: none; max-height: 0">Preview padding&zwnj;&nbsp;&zwnj;</div>
            <p>Hi Maya,</p><p>Here&rsquo;s the plan for <b>Q3</b>&nbsp;&amp; beyond:</p>
            <ul><li>Hire <i>two</i> engineers</li><li><p>Ship v2</p></li></ul>
            <ol start="3"><li>Third</li><li>Fourth</li></ol>
            <p>Line one<br>Line two<br/><br>After a gap</p><!-- <p>a comment</p> -->
            <table><tr><td>Revenue</td><td>$1.2M</td></tr><tr><td>Burn</td><td>$300K</td></tr></table>
            <p>1 &lt; 2 &#8212; caf&eacute; &#146;quoted&#146; 3 < 4</p>
            <pre>  indented
                code</pre>
            <p hidden>Hidden</p><p title="a > b">Done</p></body></html>
            """
        let raw = Mail.raw(["Content-Type: text/html; charset=utf-8"], html)
        let body = MailBody(MailMIME.parse(raw))
        XCTAssertNil(body.text)
        XCTAssertEqual(body.readableText, """
            Hi Maya,

            Here’s the plan for Q3 & beyond:

            • Hire two engineers
            • Ship v2

            3. Third
            4. Fourth

            Line one
            Line two

            After a gap

            Revenue $1.2M
            Burn $300K

            1 < 2 — café ’quoted’ 3 < 4

              indented
                code

            Done
            """)
    }

    func testQuotedHistoryInHTMLCanBeLeftOut() {
        let reply = """
            <div dir="ltr">Sounds good, sending it tomorrow.</div><br><div class="gmail_quote gmail_quote_container">\
            <div dir="ltr" class="gmail_attr">On Mon, Oct 5, 2026 at 9:12 AM Sam Lee &lt;<a href="mailto:sam.lee@northwind.example">\
            sam.lee@northwind.example</a>&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex">\
            <div>Can you send the final numbers?</div><blockquote>Older</blockquote></blockquote></div>
            """
        XCTAssertEqual(MailText.plainText(fromHTML: reply, droppingQuotes: true), "Sounds good, sending it tomorrow.")
        let whole = MailText.plainText(fromHTML: reply)
        XCTAssertTrue(whole.hasPrefix("Sounds good, sending it tomorrow.\n\nOn Mon, Oct 5, 2026 at 9:12 AM Sam Lee <sam.lee@northwind.example> wrote:"))
        XCTAssertTrue(whole.contains("Can you send the final numbers?"))
        XCTAssertEqual(MailText.plainText(fromHTML: "<p>Hi</p><blockquote type=\"cite\">Quoted</blockquote><p>Bye</p>", droppingQuotes: true), "Hi\n\nBye")
    }

    func testFlowedTextIsJoined() {
        // DelSp=yes: the mailer added a space where it wrapped, and that space goes again ("that  " keeps one).
        let raw = Mail.raw(["Content-Type: text/plain; charset=utf-8; format=flowed; delsp=yes"],
                           "This is one long para \r\ngraph, wrapped by the mailer.\r\n\r\n> A quoted line that  \r\n> goes on.\r\n-- \r\nSam")
        XCTAssertEqual(MailBody(MailMIME.parse(raw)).text, "This is one long paragraph, wrapped by the mailer.\n\n> A quoted line that goes on.\n-- \nSam")
        let kept = Mail.raw(["Content-Type: text/plain; format=flowed"], "Spaces stay \r\nbetween words.")
        XCTAssertEqual(MailBody(MailMIME.parse(kept)).text, "Spaces stay between words.")
    }

    func testBase64URL() {
        XCTAssertEqual(MailBase64.decodeURLSafe("-__-"), Data([0xFB, 0xFF, 0xFE]))
        XCTAssertEqual(MailBase64.decodeURLSafe("SGk="), Data("Hi".utf8))
        XCTAssertEqual(MailBase64.decodeURLSafe("SGk"), Data("Hi".utf8), "padding is optional")
        XCTAssertEqual(MailBase64.decodeURLSafe("SG\nk"), Data("Hi".utf8))
        XCTAssertEqual(MailBase64.decodeURLSafe(""), Data())
        XCTAssertNil(MailBase64.decodeURLSafe("A"))
        XCTAssertNil(MailBase64.decodeURLSafe("SGk!"))
        XCTAssertEqual(MailBase64.urlSafe(Data([0xFB, 0xFF, 0xFE])), "-__-")
        XCTAssertEqual(MailBase64.urlSafe(Data("Hi".utf8)), "SGk", "no padding")
        let bytes = Data((0...255).map(UInt8.init))
        XCTAssertEqual(MailBase64.decodeURLSafe(MailBase64.urlSafe(bytes)), bytes)
    }

    func testHeaderParametersAndAddressLists() {
        let type = MIMEHeaderValue(#"Text/HTML; Charset="UTF-8"; name="a;b.html"; format=flowed"#)
        XCTAssertEqual(type.value, "text/html")
        XCTAssertEqual(type.parameters, ["charset": "UTF-8", "name": "a;b.html", "format": "flowed"])

        let list = MailSender.list(#""Lee, Sam" <sam.lee@northwind.example>, Priya Shah <priya@contoso.example>; team: ops@northwind.example, (Ops desk) desk@northwind.example;, not an address, <>"#)
        XCTAssertEqual(list.map(\.address), ["sam.lee@northwind.example", "priya@contoso.example", "ops@northwind.example", "desk@northwind.example"])
        XCTAssertEqual(list.map(\.headerForm), [#""Lee, Sam" <sam.lee@northwind.example>"#, "Priya Shah <priya@contoso.example>",
                                                "ops@northwind.example", "desk@northwind.example"])
        XCTAssertEqual(MailSender.list(#"=?UTF-8?B?\#(Mail.base64("Lee, Sam"))?= <sam@northwind.example>"#).first?.name, "Lee, Sam",
                       "split before encoded words are decoded")
        XCTAssertEqual(MailSender(header: "sam.lee@northwind.example (Sam Lee)").name, "Sam Lee", "a comment after the address names it")
        XCTAssertNil(MailSender(header: "(Ops desk) desk@northwind.example").name, "one before it is only a comment")
        XCTAssertTrue(MailSender.isValidAddress("sam.lee+q3@northwind.example"))
        for bad in ["sam", "@northwind.example", "sam@", "sam lee@northwind.example", "sam@north\r\nwind.example", "<sam@x.example>"] {
            XCTAssertFalse(MailSender.isValidAddress(bad), bad)
        }
    }

    func testRawMessagesThatAreOddStillRead() {
        // No headers at all, a multipart without its closing line, and a multipart without a boundary.
        XCTAssertEqual(MailBody(MailMIME.parse(Data("Just text, no headers.".utf8))).text, "Just text, no headers.")
        let cut = Mail.raw([#"Content-Type: multipart/mixed; boundary="x""#], "--x\r\nContent-Type: text/plain\r\n\r\nPart one\r\n--x\r\n\r\nPart two")
        XCTAssertEqual(MailBody(MailMIME.parse(cut)).text, "Part one\n\nPart two")
        XCTAssertEqual(MailBody(MailMIME.parse(Mail.raw(["Content-Type: multipart/mixed"], "Text"))).text, "Text")

        // Deep nesting stops at a sane depth instead of running away.
        var nested = "Innermost"
        for level in 0..<60 {
            nested = "Content-Type: multipart/mixed; boundary=\"b\(level)\"\r\n\r\n--b\(level)\r\n\(nested)\r\n--b\(level)--"
        }
        nested = nested.replacingOccurrences(of: "\r\n\r\nInnermost", with: "Content-Type: text/plain\r\n\r\nInnermost")
        _ = MailBody(MailMIME.parse(Data(nested.utf8)))
    }
}

// MARK: - Quoted history

final class MailQuoteTests: XCTestCase {
    func testGmailStyleReplyKeepsOnlyTheNewText() {
        let text = """
            Working on it, you'll have them Thursday.

            On Mon, Oct 5, 2026 at 9:12 AM Sam Lee <sam.lee@northwind.example>
            wrote:

            > Can you send the final numbers before Friday?
            >
            > Sam
            >
            """
        XCTAssertEqual(MailQuote.trimmed(text), "Working on it, you'll have them Thursday.")
        XCTAssertEqual(MailQuote.trimmed("Thanks!\r\n\r\nOn Oct 5, 2026, at 10:42, Sam Lee <sam@northwind.example> wrote:\r\n\r\n> Done?"), "Thanks!")
        XCTAssertEqual(MailQuote.trimmed("Passt.\n\nAm 05.10.2026 um 09:12 schrieb Sam Lee <sam@northwind.example>:\n> Geht Freitag?"), "Passt.")
        XCTAssertEqual(MailQuote.trimmed("Oui.\n\nLe lun. 5 oct. 2026 à 09:12, Sam Lee <sam@northwind.example> a écrit :\n> Vendredi ?"), "Oui.")
    }

    func testAnswersBetweenQuotedLinesStay() {
        let text = """
            See my answers below.

            On Mon, Oct 5, 2026 at 9:12 AM Sam Lee <sam.lee@northwind.example> wrote:
            > Can we ship Friday?
            Yes, if QA signs off.
            > Who presents?
            Priya.
            """
        XCTAssertEqual(MailQuote.trimmed(text), "See my answers below.\n\nYes, if QA signs off.\nPriya.")
        XCTAssertEqual(MailQuote.trimmed("Agreed.\n> quoted line\n>> deeper"), "Agreed.")
    }

    func testOutlookHistoryIsCut() {
        let web = """
            Thanks, will do.

            ________________________________
            From: Sam Lee <sam@northwind.example>
            Sent: Monday, October 5, 2026 9:12 AM
            To: Maya Chen <maya@acme.example>
            Subject: Q3 numbers

            Can you send the final numbers?
            """
        XCTAssertEqual(MailQuote.trimmed(web), "Thanks, will do.")
        XCTAssertEqual(MailQuote.trimmed("OK.\n\n*From:* Sam Lee\n*Sent:* Monday\n*To:* Maya\n*Subject:* Q3\n\nOld text"), "OK.")
        XCTAssertEqual(MailQuote.trimmed("Noted.\n\n-----Original Message-----\nFrom: Sam\nOld text"), "Noted.")
    }

    func testForwardsAndOrdinaryTextStay() {
        let forward = """
            FYI, see below.

            ---------- Forwarded message ---------
            From: Sam Lee <sam@northwind.example>
            Date: Mon, Oct 5, 2026 at 9:12 AM
            Subject: Q3 numbers
            To: Maya Chen <maya@acme.example>

            Can you send the final numbers?
            """
        XCTAssertEqual(MailQuote.trimmed(forward), forward)
        let prose = "Here is what the board wrote:\nWe need to cut costs by 10%.\n\nThoughts?"
        XCTAssertEqual(MailQuote.trimmed(prose), prose, "a sentence ending in 'wrote:' isn't history")
        XCTAssertEqual(MailQuote.trimmed("  First\n\n\n\nSecond  \n\n"), "  First\n\nSecond")
    }
}

// MARK: - The reply Docket sends

final class MailReplyBuilderTests: XCTestCase {
    private func reply(from: String = #""Lee, Sam" <sam.lee@northwind.example>"#, replyTo: String? = nil,
                       to: [String] = ["Maya Chen <maya@acme.example>", "Priya Shah <priya@contoso.example>"],
                       cc: [String] = ["ops@northwind.example", "MAYA@acme.example", "Priya <priya@contoso.example>"],
                       subject: String = "Q3 numbers — final", body: String = "Thanks Sam,\nattached tomorrow.\n\nMaya",
                       all: Bool = false) -> MailReply {
        MailReply(threadID: "t1",
                  headers: MailReplyHeaders(messageID: "<CAF123@mail.northwind.example>", references: "<a1@acme.example> <a2@northwind.example>",
                                            subject: subject, from: from, replyTo: replyTo, to: to, cc: cc),
                  fromAddress: Mail.maya, body: body, replyAll: all)
    }

    private func addresses(_ list: [MailSender]) -> [String] { list.compactMap(\.address) }

    func testReplyAndReplyAllRecipients() {
        let one = MailReplyBuilder.recipients(for: reply())
        XCTAssertEqual(addresses(one.to), ["sam.lee@northwind.example"])
        XCTAssertEqual(one.cc, [])
        let all = MailReplyBuilder.recipients(for: reply(all: true))
        XCTAssertEqual(addresses(all.to), ["sam.lee@northwind.example", "priya@contoso.example"], "never me, nobody twice")
        XCTAssertEqual(addresses(all.cc), ["ops@northwind.example"])
        XCTAssertEqual(all.to.first?.name, "Lee, Sam")

        // Reply-To wins over From.
        let replyTo = reply(replyTo: #"Sales Desk <sales@northwind.example>, sam.lee@northwind.example"#)
        XCTAssertEqual(addresses(MailReplyBuilder.recipients(for: replyTo).to), ["sales@northwind.example", "sam.lee@northwind.example"])
        var replyToAll = replyTo
        replyToAll.replyAll = true
        XCTAssertEqual(addresses(MailReplyBuilder.recipients(for: replyToAll).to),
                       ["sales@northwind.example", "sam.lee@northwind.example", "priya@contoso.example"])

        // A message I sent: back to the people I sent it to.
        let mine = reply(from: "Maya Chen <maya@acme.example>", to: ["Sam Lee <sam@northwind.example>"], cc: ["priya@contoso.example"])
        XCTAssertEqual(addresses(MailReplyBuilder.recipients(for: mine).to), ["sam@northwind.example"])
        var mineAll = mine
        mineAll.replyAll = true
        XCTAssertEqual(addresses(MailReplyBuilder.recipients(for: mineAll).to), ["sam@northwind.example"])
        XCTAssertEqual(addresses(MailReplyBuilder.recipients(for: mineAll).cc), ["priya@contoso.example"])

        // A note to myself comes back to me; my other addresses are never added.
        XCTAssertEqual(addresses(MailReplyBuilder.recipients(for: reply(from: Mail.maya, to: [Mail.maya], cc: [])).to), [Mail.maya])
        let alias = MailReplyBuilder.recipients(for: reply(cc: ["ceo@acme.example", "ops@northwind.example"], all: true), ownAddresses: ["CEO@acme.example"])
        XCTAssertEqual(addresses(alias.cc), ["ops@northwind.example"])

        // My address however it's written: with a +tag, or (Gmail) with dots.
        var tagged = reply(to: ["Maya <maya+board@acme.example>", "Priya Shah <priya@contoso.example>"], cc: ["ops@northwind.example"], all: true)
        XCTAssertEqual(addresses(MailReplyBuilder.recipients(for: tagged).to), ["sam.lee@northwind.example", "priya@contoso.example"])
        tagged.fromAddress = "firstlast@gmail.com"
        tagged.headers.to = ["First.Last@gmail.com", "first.last+q3@googlemail.com", "priya@contoso.example"]
        XCTAssertEqual(addresses(MailReplyBuilder.recipients(for: tagged).to), ["sam.lee@northwind.example", "priya@contoso.example"])
        XCTAssertEqual(MailReplyBuilder.mailbox(" First.Last+q3@GoogleMail.com"), "firstlast@gmail.com")
        XCTAssertEqual(MailReplyBuilder.mailbox("first.last+q3@acme.example"), "first.last@acme.example", "dots count outside Gmail")
        XCTAssertEqual(MailReplyBuilder.identity(for: reply(to: ["Maya <maya+board@acme.example>"], cc: []),
                                                 among: [MailIdentity(address: "ceo@acme.example", isDefault: true), MailIdentity(address: Mail.maya)]).address,
                       Mail.maya, "sent to a +tag of an address of mine: from that address")

        // No address to answer: nobody, never someone else on the email the user didn't choose.
        let noSender = reply(from: "Mailer Daemon", to: ["Priya Shah <priya@contoso.example>"], cc: [])
        XCTAssertEqual(MailReplyBuilder.recipients(for: noSender).to, [])
        // A Reply-To that's me: back to me, as it asks.
        XCTAssertEqual(addresses(MailReplyBuilder.recipients(for: reply(replyTo: "maya@acme.example")).to), [Mail.maya])
    }

    func testFromIsTheAddressGmailWouldPick() {
        let identities = [MailIdentity(address: Mail.maya, name: "Maya Chen", isDefault: true),
                          MailIdentity(address: "ceo@acme.example", name: "Maya Chen (CEO)")]
        XCTAssertEqual(MailReplyBuilder.identity(for: reply(), among: identities).address, Mail.maya, "sent to her main address")
        let toAlias = reply(to: ["CEO <CEO@acme.example>"], cc: [])
        XCTAssertEqual(MailReplyBuilder.identity(for: toAlias, among: identities).address, "ceo@acme.example", "sent to an alias")
        XCTAssertEqual(MailReplyBuilder.identity(for: reply(to: ["team@acme.example"], cc: []), among: identities).address, Mail.maya,
                       "a list: the default")
        XCTAssertEqual(MailReplyBuilder.identity(for: reply(), among: []), MailIdentity(address: Mail.maya), "unknown: the connected address")
    }

    func testSubjectGetsOneRe() {
        XCTAssertEqual(MailReplyBuilder.subject(replyingTo: "Q3 numbers"), "Re: Q3 numbers")
        for kept in ["Re: Q3", "RE: Q3", "re[2]: Q3", "Re:Q3"] {
            XCTAssertEqual(MailReplyBuilder.subject(replyingTo: kept), kept)
        }
        XCTAssertEqual(MailReplyBuilder.subject(replyingTo: "Fwd: Q3"), "Re: Fwd: Q3")
        XCTAssertEqual(MailReplyBuilder.subject(replyingTo: "  "), "Re:")
    }

    func testMessageIsRFC5322WithCRLFAndBase64Body() throws {
        let date = Date(timeIntervalSince1970: 1_791_222_120)
        let data = MailReplyBuilder.message(for: reply(all: true), from: MailIdentity(address: Mail.maya, name: "Maya Chen"),
                                            date: date, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: -7 * 3600)))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF only")
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
        let parts = text.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(parts.count, 2)
        for line in parts[0].components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.count, 78, line) }
        for line in parts[1].components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.count, 76) }
        XCTAssertFalse(parts[0].lowercased().contains("message-id:"), "Gmail adds it")

        let root = MailMIME.parse(data)
        XCTAssertEqual(root.header("From"), "Maya Chen <maya@acme.example>")
        XCTAssertEqual(root.header("To"), #""Lee, Sam" <sam.lee@northwind.example>, Priya Shah <priya@contoso.example>"#)
        XCTAssertEqual(root.header("Cc"), "ops@northwind.example")
        XCTAssertTrue(root.header("Subject")?.hasPrefix("=?UTF-8?B?") == true, "not ASCII: encoded")
        XCTAssertEqual(MailText.decodeEncodedWords(root.header("Subject") ?? ""), "Re: Q3 numbers — final")
        XCTAssertEqual(root.header("In-Reply-To"), "<CAF123@mail.northwind.example>")
        XCTAssertEqual(root.header("References"), "<a1@acme.example> <a2@northwind.example> <CAF123@mail.northwind.example>")
        XCTAssertEqual(root.header("Date"), "Mon, 05 Oct 2026 10:42:00 -0700")
        XCTAssertEqual(root.header("MIME-Version"), "1.0")
        XCTAssertEqual(root.header("Content-Type"), "text/plain; charset=UTF-8")
        XCTAssertEqual(root.header("Content-Transfer-Encoding"), "base64")
        XCTAssertEqual(root.body, Data("Thanks Sam,\r\nattached tomorrow.\r\n\r\nMaya".utf8), "CRLF in the text too")
        XCTAssertEqual(MailBody(root).text, "Thanks Sam,\nattached tomorrow.\n\nMaya")

        // Long lists fold; long non-ASCII subjects become several encoded words that decode back exactly.
        let crowd = (1...12).map { "Person \($0) <person\($0)@northwind.example>" }
        let subject = String(repeating: "Résumé review — ", count: 8) + "😀 end"
        let big = MailReplyBuilder.message(for: reply(to: crowd, cc: [], subject: subject, all: true), date: date, timeZone: .current)
        let head = String(decoding: big, as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]
        for line in head.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.count, 78, line) }
        let parsed = MailMIME.parse(big)
        XCTAssertEqual(MailSender.list(parsed.header("To") ?? "").count, 13)
        XCTAssertEqual(MailText.decodeEncodedWords(parsed.header("Subject") ?? ""), "Re: " + subject)
        let words = (parsed.header("Subject") ?? "").split(separator: " ")
        XCTAssertGreaterThan(words.count, 3)
        XCTAssertTrue(words.allSatisfy { $0.count <= 75 })
        XCTAssertEqual(parsed.header("From"), Mail.maya, "no name known: the address alone")
    }

    func testNothingFromTheOriginalCanAddAHeader() {
        let evil = MailReply(threadID: "t1",
                             headers: MailReplyHeaders(messageID: "<a@b.example>\r\nBcc: spy@evil.example", references: "<c@d.example>\nBcc: spy@evil.example",
                                                       subject: "Q3\r\nBcc: spy@evil.example", from: "\"Sam\r\nBcc: spy@evil.example\" <sam@northwind.example>",
                                                       replyTo: nil),
                             fromAddress: Mail.maya, body: "Fine.", replyAll: false)
        let data = MailReplyBuilder.message(for: evil)
        let root = MailMIME.parse(data)
        XCTAssertNil(root.header("Bcc"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").contains { $0.hasPrefix("Bcc") })
        XCTAssertEqual(root.header("Subject"), "Re: Q3 Bcc: spy@evil.example")
        XCTAssertEqual(root.header("In-Reply-To"), "<a@b.example>")
        XCTAssertEqual(MailSender.list(root.header("To") ?? "").map(\.address), ["sam@northwind.example"])
    }
}

// MARK: - The Gmail client

final class GmailContentClientTests: XCTestCase {
    private func fullMessageFixture() -> String {
        let plain = "Pricing: a=3D1 stays as written <<???>> €"
        let part = { (id: String, type: String, headers: [(String, String)], body: String) in
            #"{"partId":"\#(id)","mimeType":"\#(type)","filename":"","headers":\#(Mail.headers(headers)),"body":\#(body)}"#
        }
        let top = Mail.headers([
            ("From", #""Lee, Sam" <sam.lee@northwind.example>"#),
            ("To", "Maya Chen <maya@acme.example>, Priya Shah <priya@contoso.example>"),
            ("Cc", "ops@northwind.example"),
            ("Reply-To", "Sam Lee <sam@northwind.example>"),
            ("Subject", "=?UTF-8?Q?Q3_numbers_=E2=80=94_final?="),
            ("Message-ID", "<CAF123@mail.northwind.example>"),
            ("References", "<a1@acme.example>\r\n <a2@northwind.example>"),
            ("Date", "Mon, 5 Oct 2026 09:12:00 -0700"),
            ("Content-Type", #"multipart/mixed; boundary="000""#),
        ])
        return """
            {"id":"m1","threadId":"t1","labelIds":["INBOX","STARRED"],"snippet":"Pricing: a=1","internalDate":"1791222120000",
             "payload":{"partId":"","mimeType":"multipart/mixed","filename":"","headers":\(top),"body":{"size":0},"parts":[
               {"partId":"0","mimeType":"multipart/alternative","filename":"","headers":[],"body":{"size":0},"parts":[
                 \(part("0.0", "text/plain", [("Content-Type", #"text/plain; charset="UTF-8""#), ("Content-Transfer-Encoding", "quoted-printable")],
                        #"{"size":44,"data":"\#(Mail.base64URL(plain))"}"#)),
                 \(part("0.1", "text/html", [("Content-Type", "text/html; charset=UTF-8")], #"{"size":200,"attachmentId":"ANGjdJ-html_0"}"#))]},
               {"partId":"1","mimeType":"image/png","filename":"chart.png","headers":\(Mail.headers([("Content-ID", "<chart@northwind.example>"),
                 ("Content-Disposition", #"inline; filename="chart.png""#)])),"body":{"attachmentId":"ANGjdJ-chart_1","size":2048}},
               {"partId":"2","mimeType":"application/pdf","filename":"Q3 numbers.pdf","headers":\(Mail.headers([("Content-Disposition", "attachment")])),
                "body":{"attachmentId":"ANGjdJ-pdf_2","size":52000}},
               {"partId":"3","mimeType":"application/octet-stream","filename":"notes.txt","headers":[],"body":{"size":5,"data":"aGVsbG8"}},
               {"partId":"4","mimeType":"application/pkcs7-signature","filename":"smime.p7s","headers":[],"body":{"attachmentId":"ANGjdJ-sig","size":3000}}
             ]}}
            """
    }

    func testFullMessageReadsBodiesFilesAndWhatAReplyNeeds() async throws {
        let server = FakeIntegrationServer()
        server.gmail("messages/m1", fullMessageFixture())
        server.gmail("messages/m1/attachments/ANGjdJ-html_0",
                     #"{"size":56,"data":"\#(Mail.base64URL(#"<p>Pricing</p><img src="cid:chart@northwind.example">"#))"}"#)
        let full = try await Mail.client(server).fullMessage("m1")

        let request = try XCTUnwrap(server.requests(toPath: "/gmail/v1/users/me/messages/m1").first)
        XCTAssertEqual(FakeIntegrationServer.query(request)["format"], "full")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ya29.first")

        XCTAssertEqual(full.id, "m1")
        XCTAssertEqual(full.threadID, "t1")
        let content = full.content
        XCTAssertEqual(content.text, "Pricing: a=3D1 stays as written <<???>> €", "Gmail's bodies are already decoded: only base64url is undone")
        XCTAssertEqual(content.html, #"<p>Pricing</p><img src="cid:chart@northwind.example">"#, "a body sent apart is fetched")
        XCTAssertNil(content.markup)
        XCTAssertEqual(content.to, ["Maya Chen <maya@acme.example>", "Priya Shah <priya@contoso.example>"])
        XCTAssertEqual(content.cc, ["ops@northwind.example"])
        XCTAssertEqual(content.attachments.map(\.name), ["chart.png", "Q3 numbers.pdf", "notes.txt"], "no signature")
        XCTAssertEqual(content.attachments.map(\.id), ["m1/ANGjdJ-chart_1", "m1/ANGjdJ-pdf_2", "m1/part:3"])
        XCTAssertEqual(content.attachments.map(\.remote), [.gmail(messageID: "m1", attachmentID: "ANGjdJ-chart_1"),
                                                           .gmail(messageID: "m1", attachmentID: "ANGjdJ-pdf_2"),
                                                           .gmail(messageID: "m1", attachmentID: "part:3")])
        XCTAssertEqual(content.attachments.map(\.contentID), ["chart@northwind.example", nil, nil])
        XCTAssertEqual(content.attachments.map(\.mimeType), ["image/png", "application/pdf", "text/plain"])
        XCTAssertEqual(content.attachments.map(\.size), [2048, 52000, 5])
        XCTAssertTrue(content.attachments[0].isImage)

        let headers = full.replyHeaders
        XCTAssertEqual(headers.messageID, "<CAF123@mail.northwind.example>")
        XCTAssertEqual(headers.references, "<a1@acme.example> <a2@northwind.example>")
        XCTAssertEqual(headers.subject, "Q3 numbers — final")
        XCTAssertEqual(headers.from, #""Lee, Sam" <sam.lee@northwind.example>"#)
        XCTAssertEqual(headers.replyTo, "Sam Lee <sam@northwind.example>")
        XCTAssertEqual(headers.to, ["Maya Chen <maya@acme.example>", "Priya Shah <priya@contoso.example>"])
        XCTAssertEqual(headers.cc, ["ops@northwind.example"])
    }

    func testAttachmentsAreFetchedByIDOrFoundInTheMessage() async throws {
        let server = FakeIntegrationServer()
        server.gmail("messages/m1/attachments/ANGjdJ-pdf_2", #"{"size":9,"data":"JVBERi0xLjQK"}"#)
        server.gmail("messages/m1", fullMessageFixture())
        let client = Mail.client(server)
        let pdf = try await client.attachment(messageID: "m1", attachmentID: "ANGjdJ-pdf_2")
        XCTAssertEqual(pdf, Data("%PDF-1.4\n".utf8))
        let inline = try await client.attachment(messageID: "m1", attachmentID: "part:3")
        XCTAssertEqual(inline, Data("hello".utf8))
        XCTAssertEqual(server.requests(toPath: "/gmail/v1/users/me/messages/m1").count, 1)

        for (message, attachment) in [("../m1", "ANGjdJ"), ("m1", "../../profile"), ("m1", "a/b"), ("m1", ""), ("m1", "part:../1"), ("m1", "part:9")] {
            do {
                _ = try await client.attachment(messageID: message, attachmentID: attachment)
                XCTFail("\(message) \(attachment) must fail")
            } catch {
                XCTAssertNotNil(error as? IntegrationError)
            }
        }
        XCTAssertEqual(server.requests.count, 3, "bad ids never reach Gmail; a part that isn't there is looked for once")
    }

    func testConversationIsTheEarlierMessagesWithoutQuotedHistory() async throws {
        let base = Date(timeIntervalSince1970: 1_791_200_000)
        let sam = #""Lee, Sam" <sam.lee@northwind.example>"#
        let priyaHTML = """
            {"partId":"","mimeType":"text/html","filename":"","headers":\(Mail.headers([("From", "Priya Shah <priya@contoso.example>")])),
             "body":{"size":10,"data":"\(Mail.base64URL(#"<div>Adding the forecast tab.</div><div class="gmail_quote">On Mon wrote:<blockquote>Working on it.</blockquote></div>"#))"}}
            """
        let thread = """
            {"id":"t1","messages":[
              \(Mail.message("m1", from: sam, date: base, text: "Can you send the final numbers before Friday?\r\n\r\nSam")),
              \(Mail.message("m2", labels: ["SENT"], from: "Maya Chen <maya@acme.example>", date: base.addingTimeInterval(600),
                             text: "Working on it.\r\n\r\nOn Mon, Oct 5, 2026 at 9:12 AM Sam Lee <sam.lee@northwind.example>\r\nwrote:\r\n\r\n> Can you send the final numbers before Friday?\r\n>\r\n> Sam")),
              \(Mail.message("d1", labels: ["DRAFT"], from: "Maya Chen <maya@acme.example>", date: base.addingTimeInterval(700), text: "Unsent draft")),
              \(Mail.message("m3", from: "Priya Shah <priya@contoso.example>", date: base.addingTimeInterval(1200), payload: priyaHTML)),
              \(Mail.message("x1", labels: ["TRASH"], from: sam, date: base.addingTimeInterval(1300), text: "Deleted")),
              \(Mail.message("m4", from: sam, date: base.addingTimeInterval(1800), text: "Any update?"))
            ]}
            """
        let server = FakeIntegrationServer()
        server.gmail("threads/t1", thread)
        let client = Mail.client(server)

        let earlier = try await client.conversation(threadID: "t1", excluding: "m4", limit: 2, myAddress: "MAYA@acme.example")
        XCTAssertEqual(earlier.map(\.id), ["m2", "m3"], "the latest two before it, oldest first; no drafts or trash")
        XCTAssertEqual(earlier.map(\.text), ["Working on it.", "Adding the forecast tab."])
        XCTAssertEqual(earlier.map(\.from), ["Maya Chen", "Priya Shah"])
        XCTAssertEqual(earlier.map(\.isMine), [true, false])
        XCTAssertEqual(earlier[0].date, base.addingTimeInterval(600))
        XCTAssertEqual(FakeIntegrationServer.query(try XCTUnwrap(server.requests.first))["format"], "full")

        let all = try await client.conversation(threadID: "t1", excluding: "m4", limit: 10, myAddress: Mail.maya)
        XCTAssertEqual(all.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(all[0].text, "Can you send the final numbers before Friday?\n\nSam")
        XCTAssertEqual(all[0].from, "Lee, Sam")
        let gone = try await client.conversation(threadID: "t1", excluding: "nope", limit: 10, myAddress: Mail.maya)
        XCTAssertEqual(gone.map(\.id), ["m1", "m2", "m3", "m4"], "not in the conversation: everything")
        let none = try await client.conversation(threadID: "t1", excluding: "m4", limit: 0, myAddress: Mail.maya)
        XCTAssertEqual(none, [])
        do {
            _ = try await client.conversation(threadID: "t1/../x", excluding: nil, limit: 5, myAddress: Mail.maya)
            XCTFail("a bad id must fail")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .unexpected(.gmail, "a bad conversation id"))
        }
    }

    private func sendAs(_ server: FakeIntegrationServer) {
        server.gmail("settings/sendAs", """
            {"sendAs":[{"sendAsEmail":"maya@acme.example","displayName":"Maya Chen","isDefault":true,"isPrimary":true},
                       {"sendAsEmail":"ceo@acme.example","displayName":"Maya Chen (CEO)","verificationStatus":"accepted"},
                       {"sendAsEmail":"pending@acme.example","displayName":"Not yet","verificationStatus":"pending"}]}
            """)
    }

    private func sent(_ request: URLRequest, draft: Bool = false) throws -> (raw: MIMEPart, threadID: String) {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let message = try XCTUnwrap((draft ? object["message"] : object) as? [String: Any])
        let raw = try XCTUnwrap(message["raw"] as? String)
        XCTAssertFalse(raw.contains("+") || raw.contains("/") || raw.contains("="), "base64url without padding")
        return (MailMIME.parse(try XCTUnwrap(MailBase64.decodeURLSafe(raw))), try XCTUnwrap(message["threadId"] as? String))
    }

    private let original = MailReplyHeaders(messageID: "<CAF123@mail.northwind.example>", references: nil, subject: "Q3 numbers",
                                            from: "Sam Lee <sam@northwind.example>", replyTo: nil,
                                            to: ["Maya Chen (CEO) <ceo@acme.example>"], cc: ["Priya Shah <priya@contoso.example>", Mail.maya])

    func testSendReplyGoesOutInTheConversationFromTheRightAddress() async throws {
        let server = FakeIntegrationServer()
        sendAs(server)
        server.gmail("messages/send", #"{"id":"s1","threadId":"t1","labelIds":["SENT"]}"#)
        let reply = MailReply(threadID: "t1", headers: original, fromAddress: Mail.maya, body: "Sending them now.\n\nMaya", replyAll: true)
        try await Mail.client(server).sendReply(reply)

        let request = try XCTUnwrap(server.requests(toPath: "/gmail/v1/users/me/messages/send").first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ya29.first")
        let (message, threadID) = try sent(request)
        XCTAssertEqual(threadID, "t1")
        XCTAssertEqual(MailSender(header: message.header("From") ?? "").address, "ceo@acme.example", "the address it was sent to")
        XCTAssertEqual(MailSender(header: message.header("From") ?? "").name, "Maya Chen (CEO)")
        XCTAssertEqual(MailSender.list(message.header("To") ?? "").compactMap(\.address), ["sam@northwind.example"])
        XCTAssertEqual(MailSender.list(message.header("Cc") ?? "").compactMap(\.address), ["priya@contoso.example"], "none of my addresses")
        XCTAssertEqual(message.header("Subject"), "Re: Q3 numbers")
        XCTAssertEqual(message.header("In-Reply-To"), "<CAF123@mail.northwind.example>")
        XCTAssertEqual(message.header("References"), "<CAF123@mail.northwind.example>")
        XCTAssertEqual(MailBody(message).text, "Sending them now.\n\nMaya")
        XCTAssertEqual(server.requests(toPath: "/gmail/v1/users/me/messages/send").count, 1)
    }

    func testSaveDraftWrapsTheMessage() async throws {
        let server = FakeIntegrationServer()
        server.gmail("drafts", #"{"id":"r-123","message":{"id":"d1","threadId":"t1"}}"#)
        // Without the send-as list (it failed), the reply goes from the connected address.
        let reply = MailReply(threadID: "t1", headers: original, fromAddress: Mail.maya, body: "Draft text", replyAll: false)
        try await Mail.client(server).saveDraft(reply)
        let (message, threadID) = try sent(try XCTUnwrap(server.requests(toPath: "/gmail/v1/users/me/drafts").first), draft: true)
        XCTAssertEqual(threadID, "t1")
        XCTAssertEqual(message.header("From"), Mail.maya)
        XCTAssertEqual(message.header("To"), "Sam Lee <sam@northwind.example>")
        XCTAssertNil(message.header("Cc"))
        XCTAssertTrue(server.requests(toPath: "/gmail/v1/users/me/messages/send").isEmpty, "a draft is never sent")
    }

    func testSendingRetriesOnlyAnExpiredTokenAndExplainsFailures() async throws {
        let server = FakeIntegrationServer()
        sendAs(server)
        server.gmail("messages/send",
                     .init(status: 401, body: #"{"error":{"code":401,"message":"Request had invalid authentication credentials."}}"#),
                     .init(body: #"{"id":"s1","threadId":"t1"}"#),
                     .init(status: 403, body: #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#),
                     .init(status: 400, body: #"{"error":{"code":400,"message":"Invalid To header","errors":[{"reason":"invalidArgument"}]}}"#),
                     .init(status: 429, body: #"{"error":{"code":429,"message":"Too many requests"}}"#))
        server.google("/token", .init(body: #"{"access_token":"ya29.second","expires_in":3599,"token_type":"Bearer"}"#))
        let client = Mail.client(server)
        let reply = MailReply(threadID: "t1", headers: original, fromAddress: Mail.maya, body: "Yes.", replyAll: false)

        try await client.sendReply(reply)
        let sends = server.requests(toPath: "/gmail/v1/users/me/messages/send")
        XCTAssertEqual(sends.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer ya29.first", "Bearer ya29.second"])

        let expected: [IntegrationError] = [
            .missingPermission(.gmail, "send replies and save drafts"),
            .api(.gmail, "Gmail couldn't send the reply (Invalid To header)."),
            .api(.gmail, "Gmail asked Docket to slow down, so it couldn't send the reply. Try again in a minute."),
        ]
        for want in expected {
            do {
                try await client.sendReply(reply)
                XCTFail("must fail with \(want)")
            } catch {
                XCTAssertEqual(error as? IntegrationError, want)
                XCTAssertEqual(want.errorDescription, error.localizedDescription)
            }
        }
        XCTAssertEqual(server.requests(toPath: "/gmail/v1/users/me/messages/send").count, 5, "each failure tried once")
        XCTAssertEqual(IntegrationError.missingPermission(.gmail, GmailClient.composePermission).errorDescription,
                       "Docket needs permission to send replies and save drafts. Connect Gmail again and allow it.")
    }

    func testASendThatTimesOutSaysItMayHaveGone() async throws {
        // The connection drops while Gmail has the message: it may have gone out, so no "try again" by itself.
        let flaky: IntegrationHTTP.Transport = { request in
            switch request.url?.path {
            case "/gmail/v1/users/me/messages/send": throw URLError(.timedOut)
            case "/gmail/v1/users/me/drafts": throw URLError(.networkConnectionLost)
            default: throw URLError(.timedOut)
            }
        }
        let client = GmailClient(session: Mail.session(FakeIntegrationServer(), scopes: [GoogleOAuth.gmailScope, GoogleOAuth.composeScope]),
                                 transport: flaky)
        let reply = MailReply(threadID: "t1", headers: original, fromAddress: Mail.maya, body: "Yes.", replyAll: false)
        do {
            try await client.sendReply(reply)
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? IntegrationError,
                           .api(.gmail, "Gmail didn't answer in time, so Docket can't tell if it managed to send the reply. Check Gmail before trying again."))
        }
        do {
            try await client.saveDraft(reply)
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? IntegrationError,
                           .api(.gmail, "Gmail didn't answer in time, so Docket can't tell if it managed to save the draft. Check Gmail before trying again."))
        }
        // Reading that times out is just slow.
        do {
            _ = try await client.fullMessage("m1")
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .offline(.gmail, "It took too long to answer."))
        }
    }

    func testSendingErrorsAreThePlainWordsFromGmail() {
        let scope = Data(#"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#.utf8)
        XCTAssertEqual(GmailClient.error(status: 403, data: scope, permission: GmailClient.composePermission, action: "send the reply"),
                       .missingPermission(.gmail, "send replies and save drafts"))
        let invalid = Data(#"{"error":{"code":400,"message":"Invalid To header"}}"#.utf8)
        XCTAssertEqual(GmailClient.error(status: 400, data: invalid, action: "send the reply"), .api(.gmail, "Gmail couldn't send the reply (Invalid To header)."))
        XCTAssertEqual(GmailClient.error(status: 400, data: invalid), .unexpected(.gmail, "HTTP 400"), "reading: as before")
        XCTAssertEqual(GmailClient.error(status: 429, data: Data(), action: "save the draft"),
                       .api(.gmail, "Gmail asked Docket to slow down, so it couldn't save the draft. Try again in a minute."))
        XCTAssertEqual(GmailClient.error(status: 429, data: Data()), .rateLimited(.gmail, retryAfter: 60))
    }

    func testNothingIsSentWithoutABodyOrSomeoneToSendItTo() async {
        let server = FakeIntegrationServer()
        sendAs(server)
        let client = Mail.client(server)
        let empty = MailReply(threadID: "t1", headers: original, fromAddress: Mail.maya, body: " \n ", replyAll: false)
        let nobody = MailReply(threadID: "t1", headers: MailReplyHeaders(messageID: nil, references: nil, subject: "Q3", from: "Mailer Daemon", replyTo: nil),
                               fromAddress: Mail.maya, body: "Hello?", replyAll: true)
        let badThread = MailReply(threadID: "t1?x=1", headers: original, fromAddress: Mail.maya, body: "Hi", replyAll: false)
        for (reply, expected) in [(empty, IntegrationError.api(.gmail, "The reply is empty.")),
                                  (nobody, .api(.gmail, "This email has no address to reply to.")),
                                  (badThread, .unexpected(.gmail, "a bad conversation id"))] {
            do {
                try await client.sendReply(reply)
                XCTFail("must not send")
            } catch {
                XCTAssertEqual(error as? IntegrationError, expected)
            }
        }
        XCTAssertTrue(server.requests(toPath: "/gmail/v1/users/me/messages/send").isEmpty)
    }
}

// MARK: - Permission to reply

final class GmailComposeScopeTests: XCTestCase {
    func testSignInAsksToReadAndToCompose() throws {
        XCTAssertEqual(GoogleOAuth.scopes, ["openid", "email", "https://www.googleapis.com/auth/gmail.readonly",
                                            "https://www.googleapis.com/auth/gmail.compose"])
        let url = try XCTUnwrap(GoogleOAuth.authorizationURL(client: .init(id: "1234-test.apps.googleusercontent.com", secret: "s"),
                                                             redirectURI: "http://127.0.0.1:49152", state: "st", challenge: "ch"))
        let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value
        XCTAssertEqual(scope, "openid email https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.compose")
    }

    func testCanComposeFollowsTheScopesGoogleGranted() async throws {
        let server = FakeIntegrationServer()
        let both = Mail.session(server, scopes: [GoogleOAuth.gmailScope, GoogleOAuth.composeScope])
        let canComposeWithBoth = await both.canCompose
        XCTAssertTrue(canComposeWithBoth)
        let readOnly = Mail.session(server, scopes: [GoogleOAuth.gmailScope])
        let canComposeReadOnly = await readOnly.canCompose
        XCTAssertFalse(canComposeReadOnly, "a sign-in from before replies, or compose left out on the consent screen")

        // Restored at launch: unknown (so no), until Google says, once.
        server.google("/token", .init(body: #"{"access_token":"ya29.second","expires_in":3599,"scope":"https://www.googleapis.com/auth/gmail.compose openid https://www.googleapis.com/auth/gmail.readonly","token_type":"Bearer"}"#))
        let restored = GoogleSession(client: .init(id: "id", secret: "secret"), refreshToken: "1//refresh", transport: server.transport)
        let before = await restored.canCompose
        XCTAssertFalse(before)
        let checked = try await restored.checkCanCompose()
        XCTAssertTrue(checked)
        let again = try await restored.checkCanCompose()
        XCTAssertTrue(again)
        XCTAssertEqual(server.requests(toPath: "/token").count, 1)
        let token = try await restored.accessToken()
        XCTAssertEqual(token, "ya29.second", "the refresh also gave a token")

        // A refresh without a scope list keeps what was known.
        let quiet = FakeIntegrationServer()
        quiet.google("/token", .init(body: #"{"access_token":"ya29.third","expires_in":3599,"token_type":"Bearer"}"#))
        let known = GoogleSession(client: .init(id: "id", secret: "secret"), refreshToken: "1//refresh", transport: quiet.transport,
                                  tokens: .init(accessToken: "old", expiresAt: Date().addingTimeInterval(-1), refreshToken: nil,
                                                scopes: [GoogleOAuth.gmailScope, GoogleOAuth.composeScope]))
        _ = try await known.refreshAccessToken()
        let stillKnown = await known.canCompose
        XCTAssertTrue(stillKnown)
    }
}
