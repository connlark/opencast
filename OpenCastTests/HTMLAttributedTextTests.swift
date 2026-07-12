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

    private func plainText(_ html: String) -> String {
        String(HTMLAttributedText.attributedString(from: html).characters)
    }

    private func intent(of text: String, in attributed: AttributedString) -> InlinePresentationIntent? {
        run(of: text, in: attributed)?.inlinePresentationIntent
    }

    private func link(of text: String, in attributed: AttributedString) -> URL? {
        run(of: text, in: attributed)?.link
    }

    private func run(of text: String, in attributed: AttributedString) -> AttributedString.Runs.Run? {
        attributed.runs.first { run in
            String(attributed.characters[run.range]).contains(text)
        }
    }
}
