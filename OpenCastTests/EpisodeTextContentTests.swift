import Testing
@testable import OpenCast

@MainActor
@Suite("Episode text content")
struct EpisodeTextContentTests {
    @Test("Summary text decodes entities and separates adjacent timeline entries")
    func summaryTextDecodesEntitiesAndSeparatesTimelineEntries() async {
        let content = await EpisodeTextContent.resolving(
            summaryHTML: """
            Listen to LibriVox Community Podcast #162 &#8211; Careers and LibriVox. \
            Hosted by jpercival. 0:00 \u{2013} Introduction0:22 \u{2013} Job Work as read by Larry Wilson. \
            Archive Diving \u{2013} What&#8217;s Your Time Budget for [&#8230;]
            """,
            showNotesHTML: nil
        )

        let summary = content.summary ?? ""
        #expect(summary.contains("#162 \u{2013} Careers and LibriVox"))
        #expect(summary.contains("Introduction 0:22 \u{2013} Job Work"))
        #expect(summary.contains("What\u{2019}s Your Time Budget"))
        #expect(summary.contains("&#8211;") == false)
        #expect(summary.contains("&#8217;") == false)
    }

    @Test("Show notes render as structured native text instead of embedded HTML")
    func showNotesRenderAsStructuredNativeText() async {
        let content = await EpisodeTextContent.resolving(
            summaryHTML: "Short summary.",
            showNotesHTML: """
            <figure class="wp-block-audio"><audio controls src="https://example.com/audio.mp3"></audio></figure>
            <p>Listen to <a href="https://example.com/audio.mp3">LibriVox Community Podcast #162 &#8211; Careers and LibriVox</a>. Hosted by jpercival.</p>
            <p>Duration: 12:35</p>
            <hr class="wp-block-separator"/>
            <p>0:00 \u{2013} Introduction<br>0:22 \u{2013} <a href="https://librivox.org/job-work-by-james-whitcomb-riley/">Job Work</a> as read by Larry Wilson<br>8:39\u{2013} Bloopers by ShrimpPhish</p>
            """
        )

        let showNotes = content.showNotesPlainText ?? ""
        #expect(content.showNotesShouldRender)
        #expect(showNotes.contains("<") == false)
        #expect(showNotes.contains("audio controls") == false)
        #expect(showNotes.contains("LibriVox Community Podcast #162 \u{2013} Careers and LibriVox"))
        #expect(showNotes.contains("0:22 \u{2013} Job Work"))
        #expect(showNotes.contains("8:39 \u{2013} Bloopers by ShrimpPhish"))
    }
}
