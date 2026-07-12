import Foundation
import Testing
import UserNotifications

@Suite("Artwork download accumulator")
struct ArtworkDownloadAccumulatorTests {
    @Test("Finishes all successful downloads in request order")
    func finishesAllSuccessfulDownloadsInRequestOrder() throws {
        let accumulator = try Self.accumulator()
        let podcastAttachment = try Self.pngAttachment(
            identifier: NotificationArtworkAttachmentIdentifier.podcast,
            base64EncodedPNG: Self.onePixelPNG
        )
        let episodeAttachment = try Self.pngAttachment(
            identifier: NotificationArtworkAttachmentIdentifier.episode,
            base64EncodedPNG: Self.twoPixelPNG
        )

        #expect(accumulator.complete(
            identifier: NotificationArtworkAttachmentIdentifier.episode,
            attachment: episodeAttachment
        ) == nil)
        let attachments = try #require(accumulator.complete(
            identifier: NotificationArtworkAttachmentIdentifier.podcast,
            attachment: podcastAttachment
        ))

        #expect(attachments.map(\.identifier) == [
            NotificationArtworkAttachmentIdentifier.podcast,
            NotificationArtworkAttachmentIdentifier.episode,
        ])
    }

    @Test("Finish flushes partial attachments in request order")
    func finishFlushesPartialAttachmentsInRequestOrder() throws {
        let accumulator = try Self.accumulator()
        let podcastAttachment = try Self.pngAttachment(
            identifier: NotificationArtworkAttachmentIdentifier.podcast,
            base64EncodedPNG: Self.onePixelPNG
        )
        let lateEpisodeAttachment = try Self.pngAttachment(
            identifier: NotificationArtworkAttachmentIdentifier.episode,
            base64EncodedPNG: Self.twoPixelPNG
        )

        #expect(accumulator.complete(
            identifier: NotificationArtworkAttachmentIdentifier.podcast,
            attachment: podcastAttachment
        ) == nil)
        let attachments = accumulator.finish()

        #expect(attachments.map(\.identifier) == [
            NotificationArtworkAttachmentIdentifier.podcast,
        ])
        #expect(accumulator.complete(
            identifier: NotificationArtworkAttachmentIdentifier.episode,
            attachment: lateEpisodeAttachment
        ) == nil)
        #expect(accumulator.finish().map(\.identifier) == [
            NotificationArtworkAttachmentIdentifier.podcast,
        ])
    }

    @Test("Final completion keeps successful episode artwork when podcast artwork fails")
    func finalCompletionKeepsSuccessfulEpisodeArtworkWhenPodcastArtworkFails() throws {
        let accumulator = try Self.accumulator()
        let episodeAttachment = try Self.pngAttachment(
            identifier: NotificationArtworkAttachmentIdentifier.episode,
            base64EncodedPNG: Self.twoPixelPNG
        )

        #expect(accumulator.complete(
            identifier: NotificationArtworkAttachmentIdentifier.podcast,
            attachment: nil
        ) == nil)
        let attachments = try #require(accumulator.complete(
            identifier: NotificationArtworkAttachmentIdentifier.episode,
            attachment: episodeAttachment
        ))

        #expect(attachments.map(\.identifier) == [
            NotificationArtworkAttachmentIdentifier.episode,
        ])
    }

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    private static let twoPixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGNgYPj/H4QBDfsD/Yde1YcAAAAASUVORK5CYII="

    private static func accumulator() throws -> ArtworkDownloadAccumulator {
        let podcastURL = try #require(URL(string: "https://example.com/podcast.png"))
        let episodeURL = try #require(URL(string: "https://example.com/episode.png"))

        return ArtworkDownloadAccumulator(artworkRequests: [
            ArtworkDownloadRequest(
                url: podcastURL,
                identifier: NotificationArtworkAttachmentIdentifier.podcast
            ),
            ArtworkDownloadRequest(
                url: episodeURL,
                identifier: NotificationArtworkAttachmentIdentifier.episode
            ),
        ])
    }

    private static func pngAttachment(
        identifier: String,
        base64EncodedPNG: String
    ) throws -> UNNotificationAttachment {
        let pngData = try #require(Data(base64Encoded: base64EncodedPNG))
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "artwork.png")
        try pngData.write(to: url)
        return try UNNotificationAttachment(identifier: identifier, url: url)
    }
}
