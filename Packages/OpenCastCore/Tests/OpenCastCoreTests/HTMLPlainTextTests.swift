import Foundation
import OpenCastCore
import Testing

@Suite("HTML plain text")
struct HTMLPlainTextTests {
    @Test("Each br spelling ends a line", arguments: ["<br>", "<br/>", "<br />", "<BR>"])
    func lineBreaks(tag: String) {
        #expect(HTMLPlainText.structuredText(from: "One\(tag)Two") == "One\nTwo")
    }

    @Test("A list item starts its line with a dash")
    func listItemPrefix() {
        #expect(HTMLPlainText.structuredText(from: #"<ul><li class="x">One</li></ul>After"#) == "- One\n\nAfter")
    }

    @Test("A closing block tag leaves a blank line", arguments: ["p", "div", "h2", "li"])
    func blockClosings(tag: String) {
        #expect(HTMLPlainText.structuredText(from: "A</\(tag)>B") == "A\n\nB")
    }

    @Test("Rules, figures and media become paragraph breaks and drop their content")
    func paragraphReplacements() {
        #expect(HTMLPlainText.structuredText(from: "A<hr>B<hr/>C") == "A\n\nB\n\nC")
        #expect(HTMLPlainText.structuredText(from: "A<figure><img src=x><figcaption>Cap</figcaption></figure>B") == "A\n\nB")
        #expect(HTMLPlainText.structuredText(from: "A<video src=x>Fallback</video>B") == "A\n\nB")
    }

    @Test("Timestamp paragraphs become lines with one blank line between")
    func timestampParagraphs() {
        #expect(
            HTMLPlainText.structuredText(from: "<p>00:00 Intro</p><p>05:10 Topic</p>") == "00:00 Intro\n\n05:10 Topic"
        )
    }

    @Test("Timestamp list items become dash-led lines separated by blank lines")
    func timestampListItems() {
        let html = "<ul><li>00:00 Intro</li><li>05:10 Topic</li><li>45:00 Outro</li></ul>"
        #expect(HTMLPlainText.structuredText(from: html) == "- 00:00 Intro\n\n- 05:10 Topic\n\n- 45:00 Outro")
    }

    @Test("Timestamps split by br become adjacent lines")
    func timestampLineBreaks() {
        let html = "<p>(00:02:16) Investing<br>8:39 \u{2013} Bloopers<br>1:02:33 Topic<br>[12:05] Q&amp;A</p>"
        #expect(
            HTMLPlainText.structuredText(from: html)
                == "(00:02:16) Investing\n8:39 \u{2013} Bloopers\n1:02:33 Topic\n[12:05] Q&A"
        )
    }

    @Test(
        "Tags inside a line collapse to single spaces",
        arguments: [
            ("<p><strong>00:00</strong> Intro</p>", "00:00 Intro"),
            (#"<p><a href="https://example.com/?t=0">00:00</a> Intro</p>"#, "00:00 Intro"),
            (#"<span class="x">Hello</span>   <font>world</font>"#, "Hello world"),
            ("<b>bold</b>text", "bold text")
        ]
    )
    func inlineTags(html: String, expected: String) {
        #expect(HTMLPlainText.structuredText(from: html) == expected)
    }

    @Test("A timestamp glued to the following word gains a space")
    func timestampGluedToWord() {
        #expect(HTMLPlainText.structuredText(from: "12:34Topic") == "12:34 Topic")
    }

    @Test(
        "A dash after a single-digit-minute timestamp gets one space on each side",
        arguments: [
            ("8:39-Topic", "8:39 - Topic"),
            ("8:39 \u{2013}Topic", "8:39 \u{2013} Topic"),
            ("8:39\u{2014}Topic", "8:39 \u{2014} Topic"),
            ("8:39   -   Topic", "8:39 - Topic")
        ]
    )
    func singleDigitTimelineDashes(text: String, expected: String) {
        #expect(HTMLPlainText.structuredText(from: text) == expected)
    }

    @Test(
        "A dash after a two-digit-minute timestamp gets one space on each side and the digits stay whole",
        arguments: [
            ("12:34-Topic", "12:34 - Topic"),
            ("12:34 \u{2013}Topic", "12:34 \u{2013} Topic"),
            ("12:34\u{2014}Topic", "12:34 \u{2014} Topic"),
            ("00:00 - Intro", "00:00 - Intro"),
            ("1:02:33-Topic", "1:02:33 - Topic")
        ]
    )
    func twoDigitTimelineDashes(text: String, expected: String) {
        #expect(HTMLPlainText.structuredText(from: text) == expected)
    }

    @Test(
        "Timestamps with two-digit minutes before a dash pass through whole",
        arguments: [
            "12:10 \u{2014} \"quoted\"",
            "00:02:23 - Pre-show",
            "45:00 - Wrap",
            "1:02:10 \u{2013} Title",
            "10:05 - Ten",
            "59:59 \u{2013} Last"
        ]
    )
    func twoDigitTimelineEntriesPassThrough(text: String) {
        #expect(HTMLPlainText.structuredText(from: text) == text)
    }

    @Test("A list of two-digit-minute entries comes out one whole timestamp per line")
    func twoDigitTimelineList() {
        let html = "<p>00:00 - Intro<br>12:30 - Topic<br>45:00 - Wrap</p>"
        #expect(HTMLPlainText.structuredText(from: html) == "00:00 - Intro\n12:30 - Topic\n45:00 - Wrap")
    }

    @Test("Collapsed text keeps two-digit-minute timestamps whole")
    func twoDigitTimelineCollapsed() {
        #expect(HTMLPlainText.collapsedText(from: "00:00 - Intro\n12:30 - Topic") == "00:00 - Intro 12:30 - Topic")
    }

    @Test(
        "A timeline entry glued to the previous word or closing parenthesis is split from it",
        arguments: [
            ("0:00 \u{2013} Introduction0:22 \u{2013} Job", "0:00 \u{2013} Introduction 0:22 \u{2013} Job"),
            ("Introduction0:22 \u{2013} Job Work", "Introduction 0:22 \u{2013} Job Work"),
            ("(Part 2)0:22 \u{2013} Job", "(Part 2) 0:22 \u{2013} Job"),
            ("Intro05:10 \u{2013} Topic", "Intro 05:10 \u{2013} Topic")
        ]
    )
    func joinedTimelineEntries(text: String, expected: String) {
        #expect(HTMLPlainText.structuredText(from: text) == expected)
    }

    @Test(
        "A timeline entry glued to a numeral that is not a decimal digit is split from it",
        arguments: [
            ("Part \u{2161}0:22 \u{2013} Job", "Part \u{2161} 0:22 \u{2013} Job"),
            ("x\u{00B2}0:22 \u{2013} Job", "x\u{00B2} 0:22 \u{2013} Job")
        ]
    )
    func joinedToNonDecimalNumeral(text: String, expected: String) {
        #expect(HTMLPlainText.structuredText(from: text) == expected)
    }

    @Test("A digit directly before a timestamp is left alone")
    func digitBeforeTimestamp() {
        #expect(HTMLPlainText.structuredText(from: "Top 100:22 \u{2013} Job") == "Top 100:22 \u{2013} Job")
    }

    @Test(
        "Bracketed timestamps and timestamps with no dash or word glued after them pass through",
        arguments: ["(00:00) - Intro", "[05:10] \u{2013} Topic", "45:00 Outro", "Topic 12:34"]
    )
    func timestampsLeftAlone(text: String) {
        #expect(HTMLPlainText.structuredText(from: text) == text)
    }

    @Test(
        "Named, decimal and hex entities decode",
        arguments: [
            ("Fish &amp; Chips", "Fish & Chips"),
            ("&lt;b&gt; &quot;q&quot; &apos;a&apos;", "<b> \"q\" 'a'"),
            (
                "&ndash; &mdash; &lsquo;&rsquo; &ldquo;&rdquo; &hellip; &copy; &reg;",
                "\u{2013} \u{2014} \u{2018}\u{2019} \u{201C}\u{201D} \u{2026} \u{00A9} \u{00AE}"
            ),
            ("&#8211; &#65;", "\u{2013} A"),
            ("&#x2014; &#x41;", "\u{2014} A"),
            ("&amp;amp;", "&"),
            ("&amp;lt;b&amp;gt;", "<b>"),
            ("&amp;amp;amp;amp;", "&amp;")
        ]
    )
    func entities(text: String, expected: String) {
        #expect(HTMLPlainText.decodeEntities(in: text) == expected)
    }

    @Test(
        "Unrecognised entities pass through unchanged",
        arguments: ["&unknown;", "&AMP;", "&#X41;", "&#xZZ;", "&#99999999;"]
    )
    func unrecognisedEntities(text: String) {
        #expect(HTMLPlainText.decodeEntities(in: text) == text)
    }

    @Test("Non-breaking spaces become plain spaces")
    func nonBreakingSpaces() {
        #expect(HTMLPlainText.decodeEntities(in: "a&nbsp;b") == "a b")
        #expect(HTMLPlainText.structuredText(from: "<p>a&nbsp;b\u{00A0}c</p>") == "a b c")
        #expect(HTMLPlainText.structuredText(from: "a\u{00A0}\u{00A0}b") == "a b")
    }

    @Test("Comments, scripts and styles vanish with their content")
    func hiddenContent() {
        let html = "<!-- note -->A<script>var x = 1;</script>B<style>p { color: red; }</style>C<noscript>D</noscript>"
        #expect(HTMLPlainText.structuredText(from: html) == "A B C")
    }

    @Test("CRLF and bare CR become LF")
    func carriageReturns() {
        #expect(HTMLPlainText.structuredText(from: "a\r\nb\rc") == "a\nb\nc")
        #expect(HTMLPlainText.structuredText(from: "<p>a\r\nb\rc</p>") == "a\nb\nc")
    }

    @Test("Three or more newlines collapse to two")
    func repeatedNewlines() {
        #expect(HTMLPlainText.structuredText(from: "a\n\n\nb\n\n\n\n\nc") == "a\n\nb\n\nc")
        #expect(HTMLPlainText.structuredText(from: "<p>A</p><p></p><p></p><p>B</p>") == "A\n\nB")
    }

    @Test("Plain text passes through with only the spacing rules applied")
    func plainTextPassThrough() {
        #expect(
            HTMLPlainText.structuredText(from: "  plain  text\twith   spaces \n next \n\n\n line  ")
                == "plain text with spaces\nnext\n\nline"
        )
        #expect(
            HTMLPlainText.structuredText(from: "0:00 \u{2013} Intro\n8:39 \u{2013} Bloopers")
                == "0:00 \u{2013} Intro\n8:39 \u{2013} Bloopers"
        )
        #expect(HTMLPlainText.structuredText(from: "") == "")
    }

    @Test(
        "Collapsed text is the structured text on one line",
        arguments: [
            "<p>00:00 Intro</p><ul><li>05:10 Topic</li></ul>",
            "One<br>Two<hr>Three",
            "a\r\nb\n\n\nc",
            "<p>(00:02:16) Investing<br>8:39 \u{2013} Bloopers</p>"
        ]
    )
    func collapsedText(html: String) {
        let collapsed = HTMLPlainText.collapsedText(from: html)
        let structured = HTMLPlainText.structuredText(from: html)
        #expect(collapsed == structured.replacing(/\s+/, with: " "))
        #expect(!collapsed.contains("\n"))
    }

    @Test("Collapsed text joins block lines with single spaces")
    func collapsedTextExample() {
        #expect(
            HTMLPlainText.collapsedText(from: "<p>00:00 Intro</p><ul><li>05:10 Topic</li></ul>")
                == "00:00 Intro - 05:10 Topic"
        )
    }
}
