import Testing
@testable import OpenCast

@MainActor
@Suite("Episode text content")
struct EpisodeTextContentTests {
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
