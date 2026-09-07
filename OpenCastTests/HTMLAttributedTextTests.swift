import Foundation
import Testing
@testable import OpenCast

@Suite("HTML attributed text")
struct HTMLAttributedTextTests {
    @Test("Block tags become paragraph breaks and inner whitespace collapses")
    func paragraphBreaks() {
        let text = plainText("<p>First   paragraph</p>\n   <p>Second</p>")
        #expect(text == "First paragraph\n\nSecond")
    }

    @Test("br produces a single line break")
    func lineBreaks() {
        #expect(plainText("Line one<br>Line two") == "Line one\nLine two")
    }

    @Test("Bold and emphasis map to inline presentation intents")
    func inlineIntents() {
        let attributed = HTMLAttributedText.attributedString(from: "<p><b>Bold</b> and <em>italic</em> plain</p>")

        #expect(intent(of: "Bold", in: attributed) == .stronglyEmphasized)
        #expect(intent(of: "italic", in: attributed) == .emphasized)
        #expect(intent(of: "plain", in: attributed) == nil)
    }

    @Test("Strong inside emphasis carries both intents")
    func nestedIntents() {
        let attributed = HTMLAttributedText.attributedString(from: "<em><strong>both</strong></em>")
        #expect(intent(of: "both", in: attributed) == [.stronglyEmphasized, .emphasized])
    }

    @Test("Headings render as strongly emphasized paragraphs")
    func headings() {
        let attributed = HTMLAttributedText.attributedString(from: "<h2>Title</h2><p>Body</p>")

        #expect(String(attributed.characters) == "Title\n\nBody")
        #expect(intent(of: "Title", in: attributed) == .stronglyEmphasized)
        #expect(intent(of: "Body", in: attributed) == nil)
    }

    @Test("List items get bullet prefixes on their own lines")
    func bullets() {
        let text = plainText("<ul><li>One</li><li>Two</li></ul>After")
        #expect(text == "• One\n• Two\n\nAfter")
    }

    @Test("http, https, and mailto links survive with decoded hrefs")
    func links() {
        let attributed = HTMLAttributedText.attributedString(
            from: #"<a href="https://example.com/a?x=1&amp;y=2">Link</a> and <a href="mailto:hi@example.com">mail</a>"#
        )

        #expect(link(of: "Link", in: attributed) == URL(string: "https://example.com/a?x=1&y=2"))
        #expect(link(of: "mail", in: attributed) == URL(string: "mailto:hi@example.com"))
    }

    @Test("Non-web link schemes are stripped but their text remains")
    func disallowedLinkSchemes() {
        let attributed = HTMLAttributedText.attributedString(from: #"<a href="javascript:alert(1)">tap me</a>"#)

        #expect(String(attributed.characters) == "tap me")
        #expect(link(of: "tap me", in: attributed) == nil)
    }

    @Test("Named and numeric entities decode")
    func entities() {
        let text = plainText("<p>Fish &amp; Chips &mdash; tonight&rsquo;s show &#8211; live&nbsp;now</p>")
        #expect(text == "Fish & Chips \u{2014} tonight\u{2019}s show \u{2013} live now")
    }

    @Test("Phone numbers gain tel links")
    func phoneNumbers() {
        let attributed = HTMLAttributedText.attributedString(from: "<p>Call us at (555) 123-4567 today.</p>")

        let phoneLink = attributed.runs.compactMap(\.link).first { $0.scheme == "tel" }
        #expect(phoneLink != nil)
        #expect(phoneLink?.absoluteString.contains("5551234567") == true)
    }

    @Test("Phone detection never overwrites an existing link")
    func phoneInsideLinkKeepsLink() {
        let attributed = HTMLAttributedText.attributedString(
            from: #"<a href="https://example.com">(555) 123-4567</a>"#
        )

        let links = attributed.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://example.com")])
    }

    @Test("Script, style, and figure content is stripped")
    func strippedContainers() {
        let text = plainText("<script>var x = 1;</script><figure><figcaption>Cap</figcaption></figure><p>Visible</p>")
        #expect(text == "Visible")
    }

    @Test("Malformed markup degrades to readable text without crashing")
    func malformedInput() {
        #expect(plainText("Broken <b unclosed tag soup").contains("Broken"))
        #expect(plainText("a<p>never closed") == "a\n\nnever closed")
        #expect(plainText("") == "")
    }

    @Test("Unknown inline tags are stripped without adding separators")
    func unknownTagsStripped() {
        #expect(plainText(#"<span class="x">Hello</span> <font>world</font>"#) == "Hello world")
    }

    @Test("Paragraphs split into blocks for lazy rendering, attributes intact")
    func attributedBlocks() {
        let blocks = HTMLAttributedText.attributedBlocks(from: "<p>One</p><p>Two <b>bold</b></p><p>Three</p>")

        #expect(blocks.map { String($0.characters) } == ["One", "Two bold", "Three"])
        #expect(intent(of: "bold", in: blocks[1]) == .stronglyEmphasized)
        #expect(HTMLAttributedText.attributedBlocks(from: "").isEmpty)
    }

    @Test("Show-notes timestamps gain seek links covering exactly the digits")
    func timestampsGainSeekLinks() {
        let attributed = HTMLAttributedText.attributedString(
            from: "<p>(00:02:16) Investing<br>8:39 \u{2013} Bloopers<br>1:02:33 Topic<br>[12:05] Q&amp;A</p>"
        )

        #expect(timestampSeconds(of: "00:02:16", in: attributed) == 136)
        #expect(timestampSeconds(of: "8:39", in: attributed) == 519)
        #expect(timestampSeconds(of: "1:02:33", in: attributed) == 3753)
        #expect(timestampSeconds(of: "12:05", in: attributed) == 725)

        let linkedTexts = attributed.runs.compactMap { run in
            run.link.map { _ in String(attributed.characters[run.range]) }
        }
        #expect(linkedTexts == ["00:02:16", "8:39", "1:02:33", "12:05"])
    }

    @Test("Clock times, fractions, ISO dates, and out-of-range digits are not timestamps")
    func timestampsRejectNonTimestamps() {
        let attributed = HTMLAttributedText.attributedString(
            from: "<p>10:75 60:30 123:45 12:34:56:78 2026-09-06T10:30:00Z 8:39 am 8:39pm 8:39 P.M. 16:9 3:16.5</p>"
        )

        let timestampLinks = attributed.runs.compactMap(\.link).compactMap(ShowNotesTimestampLink.seconds(from:))
        #expect(timestampLinks.isEmpty)
    }

    @Test("A timestamp followed by a word that starts with am still links")
    func timestampAfterClockWordStillLinks() {
        let attributed = HTMLAttributedText.attributedString(from: "<p>8:39 amazing guest</p>")
        #expect(timestampSeconds(of: "8:39", in: attributed) == 519)
    }

    @Test("Timestamp detection never overwrites an existing link")
    func timestampsNeverOverwriteAnchorLinks() {
        let attributed = HTMLAttributedText.attributedString(
            from: #"<a href="https://example.com/?t=136">02:16</a>"#
        )

        #expect(attributed.runs.compactMap(\.link) == [URL(string: "https://example.com/?t=136")])
    }

    @Test("Timestamps and phone numbers link side by side")
    func timestampsAndPhoneNumbersCoexist() {
        let attributed = HTMLAttributedText.attributedString(from: "<p>Call (555) 123-4567 at 10:30</p>")

        let links = attributed.runs.compactMap(\.link)
        #expect(links.count == 2)
        #expect(links.contains { $0.scheme == "tel" })
        #expect(timestampSeconds(of: "10:30", in: attributed) == 630)
    }

    @Test("Timestamp links survive the paragraph split")
    func attributedBlocksKeepTimestampLinks() {
        let blocks = HTMLAttributedText.attributedBlocks(from: "<p>Intro</p><p>8:39 \u{2013} Bloopers</p>")

        #expect(blocks.count == 2)
        #expect(blocks.last.flatMap { timestampSeconds(of: "8:39", in: $0) } == 519)
    }

    private func plainText(_ html: String) -> String {
        String(HTMLAttributedText.attributedString(from: html).characters)
    }

    private func intent(of text: String, in attributed: AttributedString) -> InlinePresentationIntent? {
        run(of: text, in: attributed)?.inlinePresentationIntent
    }

    private func link(of text: String, in attributed: AttributedString) -> URL? {
        run(of: text, in: attributed)?.link
    }

    private func timestampSeconds(of text: String, in attributed: AttributedString) -> TimeInterval? {
        link(of: text, in: attributed).flatMap(ShowNotesTimestampLink.seconds(from:))
    }

    private func run(of text: String, in attributed: AttributedString) -> AttributedString.Runs.Run? {
        attributed.runs.first { run in
            String(attributed.characters[run.range]).contains(text)
        }
    }
}
