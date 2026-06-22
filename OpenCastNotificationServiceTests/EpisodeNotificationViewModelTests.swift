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

        #expect(viewModel.summaryText == "Summary & context.")
    }

    @Test("Legacy body summary strips tags after double entity decoding")
    func legacyBodySummaryStripsTagsAfterDoubleEntityDecoding() throws {
        let scriptContent = UNMutableNotificationContent()
        scriptContent.body = "44 min\n\n&amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;"

        let scriptSummary = try #require(EpisodeNotificationViewModel(content: scriptContent).summaryText)
        #expect(!scriptSummary.contains("<"))
        #expect(!scriptSummary.contains(">"))

        let formattedContent = UNMutableNotificationContent()
        formattedContent.body = "44 min\n\n&amp;lt;b&amp;gt;Bold&amp;lt;/b&amp;gt;"

        #expect(EpisodeNotificationViewModel(content: formattedContent).summaryText == "Bold")
    }

    @Test("Legacy body summary strips malformed tag debris")
    func legacyBodySummaryStripsMalformedTagDebris() {
        let content = UNMutableNotificationContent()
        content.body = "44 min\n\npWe spend the hour in deep time. /pVisit a href=https://example.com"

        let viewModel = EpisodeNotificationViewModel(content: content)

        #expect(viewModel.durationText == "44 MIN")
        #expect(viewModel.summaryText == "We spend the hour in deep time.")
    }

    @Test("Legacy body summary keeps legitimate p-prefixed prose")
    func legacyBodySummaryKeepsLegitimatePPrefixedProse() {
        let content = UNMutableNotificationContent()
        content.body = "pH balance and p5 protocol matter. Please Subscribe"

        let viewModel = EpisodeNotificationViewModel(content: content)

        #expect(viewModel.summaryText == "pH balance and p5 protocol matter. Please Subscribe")
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

    private static func pngAttachment() throws -> UNNotificationAttachment {
        let pngData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        ))
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "artwork.png")
        try pngData.write(to: url)
        return try UNNotificationAttachment(identifier: "artwork", url: url)
    }
}
