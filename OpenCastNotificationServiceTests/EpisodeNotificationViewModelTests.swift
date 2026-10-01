import Foundation
import Testing
import UserNotifications

@Suite("Episode notification content view model")
struct EpisodeNotificationViewModelTests {
    @Test("Payload fields override body fallbacks where appropriate")
    func payloadFieldsOverrideBodyFallbacks() {
        let content = UNMutableNotificationContent()
        content.title = "The Rest Is Science"
        content.subtitle = "A Paleontology Of The Future"
        content.body = "44 min\n\nLegacy body summary."
        content.userInfo = [
            "opencast": [
                "kind": "episode",
                "episode_duration_text": "1 hr 6 min",
                "episode_summary": "Clean payload summary.",
            ],
        ]

        let viewModel = EpisodeNotificationViewModel(content: content)

        #expect(viewModel.podcastTitle == "The Rest Is Science")
        #expect(viewModel.episodeTitle == "A Paleontology Of The Future")
        #expect(viewModel.durationText == "1 HR 6 MIN")
        #expect(viewModel.summaryText == "Clean payload summary.")
        #expect(viewModel.podcastInitials == "TR")
    }

    @Test("Payload title fallbacks are used when alert title fields are empty")
    func payloadTitleFallbacksAreUsedWhenAlertFieldsAreEmpty() {
        let content = UNMutableNotificationContent()
        content.userInfo = [
            "opencast": [
                "kind": "episode",
                "podcast_title": "Payload Podcast",
                "episode_title": "Payload Episode",
            ],
        ]

        let viewModel = EpisodeNotificationViewModel(content: content)

        #expect(viewModel.podcastTitle == "Payload Podcast")
        #expect(viewModel.episodeTitle == "Payload Episode")
        #expect(viewModel.summaryText == nil)
        #expect(viewModel.artworkImage == nil)
    }

    @Test("Legacy duration is removed from body summary")
    func legacyDurationIsRemovedFromBodySummary() {
        let content = UNMutableNotificationContent()
        content.body = "44 min\n\nLegacy summary text."

        let viewModel = EpisodeNotificationViewModel(content: content)

        #expect(viewModel.durationText == "44 MIN")
        #expect(viewModel.summaryText == "Legacy summary text.")
    }

    @Test("Payload summary uses light validation")
    func payloadSummaryUsesLightValidation() {
        let content = UNMutableNotificationContent()
        content.subtitle = "A Paleontology Of The Future"
        content.userInfo = [
            "opencast": [
                "kind": "episode",
                "episode_summary": "Useful prose about foo:// URI schemes.",
            ],
        ]

        let viewModel = EpisodeNotificationViewModel(content: content)

        #expect(viewModel.summaryText == "Useful prose about foo:// URI schemes.")
    }

    @Test("Legacy body summary strips escaped HTML and URL debris")
    func legacyBodySummaryStripsEscapedHTMLAndURLDebris() {
        let content = UNMutableNotificationContent()
        content.subtitle = "A Paleontology Of The Future"
        content.body = "44 min\n\n&lt;p&gt;Summary &amp; context.&lt;/p&gt; https://example.com/read-more"

        let viewModel = EpisodeNotificationViewModel(content: content)

        #expect(viewModel.summaryText == "Summary & context. example.com")
    }

    @Test("Legacy body summary keeps double-escaped markup out")
    func legacyBodySummaryKeepsDoubleEscapedMarkupOut() {
        // A script element renders nothing, so nothing is left to show.
        let scriptContent = UNMutableNotificationContent()
        scriptContent.body = "44 min\n\n&amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;"

        #expect(EpisodeNotificationViewModel(content: scriptContent).summaryText == nil)

        let formattedContent = UNMutableNotificationContent()
        formattedContent.body = "44 min\n\n&amp;lt;b&amp;gt;Bold&amp;lt;/b&amp;gt;"

        #expect(EpisodeNotificationViewModel(content: formattedContent).summaryText == "Bold")
    }

    @Test("Legacy body summary drops unterminated markup and attribute debris")
    func legacyBodySummaryDropsUnterminatedMarkupAndAttributeDebris() {
        let unterminated = UNMutableNotificationContent()
        unterminated.body = "44 min\n\nIntro <a href=\"https://example.com/very-long"

        #expect(EpisodeNotificationViewModel(content: unterminated).durationText == "44 MIN")
        #expect(EpisodeNotificationViewModel(content: unterminated).summaryText == "Intro")

        let debris = UNMutableNotificationContent()
        debris.body = "We spend the hour. Visit a href=https://example.com target=_blank now"

        #expect(EpisodeNotificationViewModel(content: debris).summaryText == "We spend the hour. Visit now")
    }

    @Test("Legacy body summary renders inline and block elements like a browser")
    func legacyBodySummaryRendersInlineAndBlockElementsLikeABrowser() {
        let content = UNMutableNotificationContent()
        content.body = "<p>Talk with <strong>Sam</strong>, <em>Ann</em> and <a href=\"/x\">Lee</a>.</p><p>Then</p><ul><li>A</li><li>B</li></ul>"

        #expect(EpisodeNotificationViewModel(content: content).summaryText == "Talk with Sam, Ann and Lee. Then A B")

        let spaced = UNMutableNotificationContent()
        spaced.body = "parents , and then ; done ."

        #expect(EpisodeNotificationViewModel(content: spaced).summaryText == "parents, and then; done.")
    }

    @Test("Legacy body summary decodes entities to real characters and keeps a lone angle bracket")
    func legacyBodySummaryDecodesEntitiesToRealCharacters() {
        let content = UNMutableNotificationContent()
        content.body = "Ben &amp; Jerry&rsquo;s &ldquo;show&rdquo; &mdash; caf&eacute; &#8217;&#146; &unknown; 1 &lt; 2 and <3"

        #expect(
            EpisodeNotificationViewModel(content: content).summaryText
                == "Ben & Jerry\u{2019}s \u{201C}show\u{201D} \u{2014} caf\u{E9} \u{2019}\u{2019} &unknown; 1 < 2 and <3"
        )
    }

    @Test("Patreon-wrapped description becomes the whole sentence")
    func patreonWrappedDescriptionBecomesTheWholeSentence() {
        // A 2026-09-29 production push carried only "The hosts discuss the"
        // after a byte cut of markup shaped like this; the cleaner must yield
        // the full prose.
        let content = UNMutableNotificationContent()
        content.subtitle = "Episode Title"
        content.body = "44 min\n\n<div> <div class=\"patreon-post-content\"> <div class=\"PaddingTop-module__FYUbOa__paddingTopSpaceX32\"> <div class=\"CollapsibleContent-module__7CXqlq__singleColumnMargin\"> <div class=\"TokenOverrides-module__yhJOLG__tokensPostPage\"> <div class= \"RichText-module__5kju5G__root RichText-module__5kju5G__additionalStylesPostContentWrapper\"> <p>The hosts discuss the <a href= \"https://www.globe.example.com/2026/09/22/magazine/small-town-bar-backlash/?utm_campaign=Globe_Twitter&arch=example%3Asocialflow%3Atwitter\" target=\"_blank\" rel=\"noopener\">small-town bar masking debacle,</a> the hot new trend of <a href= \"https://www.journal.example.com/health/wellness/why-are-so-many-adults-cutting-off-their-parents-d4e1190c\" target=\"_blank\" rel=\"noopener\">adults cutting off their parents</a>, and <a href= \"https://www.times.example.com/2026/09/20/magazine/public-schools-segregation.html\" target=\"_blank\" rel=\"noopener\">a columnist's schooling mea culpa to her daughter.</a></p> </div> </div> </div> </div> </div> </div>"

        #expect(
            EpisodeNotificationViewModel(content: content).summaryText
                == "The hosts discuss the small-town bar masking debacle, the hot new trend of adults cutting off their parents, and a columnist's schooling mea culpa to her daughter."
        )
    }

    @Test("Title-only and URL-only summaries are hidden")
    func titleOnlyAndURLOnlySummariesAreHidden() {
        let titleOnly = UNMutableNotificationContent()
        titleOnly.subtitle = "Episode Title"
        titleOnly.userInfo = [
            "opencast": [
                "kind": "episode",
                "episode_summary": " Episode Title ",
            ],
        ]

        let urlOnly = UNMutableNotificationContent()
        urlOnly.userInfo = [
            "opencast": [
                "kind": "episode",
                "episode_summary": "https://example.com/episode",
            ],
        ]

        #expect(EpisodeNotificationViewModel(content: titleOnly).summaryText == nil)
        #expect(EpisodeNotificationViewModel(content: urlOnly).summaryText == nil)
    }

    @Test("Missing payload falls back quietly")
    func missingPayloadFallsBackQuietly() {
        let content = UNMutableNotificationContent()
        content.body = "New episode available"

        let viewModel = EpisodeNotificationViewModel(content: content)

        #expect(viewModel.podcastTitle == "OpenCast")
        #expect(viewModel.episodeTitle == "New episode")
        #expect(viewModel.durationText == nil)
        #expect(viewModel.summaryText == nil)
        #expect(viewModel.podcastInitials == "OC")
        #expect(viewModel.accessibilityLabel == "OpenCast, New episode")
    }

    @Test("Local notification attachment loads as artwork")
    func localNotificationAttachmentLoadsAsArtwork() throws {
        let content = UNMutableNotificationContent()
        let attachment = try Self.pngAttachment()
        content.attachments = [attachment]

        let viewModel = EpisodeNotificationViewModel(content: content)

        #expect(viewModel.artworkImage != nil)
    }

    @Test("Episode artwork attachment is preferred over compact artwork")
    func episodeArtworkAttachmentIsPreferredOverCompactArtwork() throws {
        let content = UNMutableNotificationContent()
        content.attachments = [
            try Self.pngAttachment(
                identifier: NotificationArtworkAttachmentIdentifier.podcast,
                base64EncodedPNG: Self.onePixelPNG
            ),
            try Self.pngAttachment(
                identifier: NotificationArtworkAttachmentIdentifier.episode,
                base64EncodedPNG: Self.twoPixelPNG
            ),
        ]

        let image = try #require(EpisodeNotificationViewModel(content: content).artworkImage)

        #expect(image.size.width == 2)
        #expect(image.size.height == 1)
    }

    @Test("Unreadable episode artwork falls back to podcast artwork")
    func unreadableEpisodeArtworkFallsBackToPodcastArtwork() throws {
        let podcastArtwork = try Self.pngAttachment(
            identifier: NotificationArtworkAttachmentIdentifier.podcast,
            base64EncodedPNG: Self.onePixelPNG
        )
        let unreadableEpisodeArtwork = try Self.pngAttachment(
            identifier: NotificationArtworkAttachmentIdentifier.episode,
            base64EncodedPNG: Self.twoPixelPNG
        )
        try FileManager.default.removeItem(at: unreadableEpisodeArtwork.url)

        let content = UNMutableNotificationContent()
        content.attachments = [podcastArtwork, unreadableEpisodeArtwork]

        let image = try #require(EpisodeNotificationViewModel(content: content).artworkImage)

        #expect(image.size.width == 1)
        #expect(image.size.height == 1)
    }

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    private static let twoPixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGNgYPj/H4QBDfsD/Yde1YcAAAAASUVORK5CYII="

    private static func pngAttachment(
        identifier: String = "artwork",
        base64EncodedPNG: String = onePixelPNG
    ) throws -> UNNotificationAttachment {
        let pngData = try #require(Data(base64Encoded:
            base64EncodedPNG
        ))
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "artwork.png")
        try pngData.write(to: url)
        return try UNNotificationAttachment(identifier: identifier, url: url)
    }
}
