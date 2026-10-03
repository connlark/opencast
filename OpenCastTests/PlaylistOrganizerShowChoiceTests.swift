import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Playlist organizer show choices")
struct PlaylistOrganizerShowChoiceTests {
    private static let aardvarkFeed = "https://example.com/aardvark.xml"
    private static let middleFeed = "https://example.com/middle.xml"
    private static let zephyrFeed = "https://example.com/zephyr.xml"

    @Test("The builder keeps library order and keeps the first record of a feed URL")
    func keepsLibraryOrderAndCollapsesTwins() {
        let subscriptions = [
            SubscriptionRecord(feedURL: Self.aardvarkFeed, title: "Aardvark"),
            SubscriptionRecord(feedURL: Self.middleFeed, title: "Middle"),
            SubscriptionRecord(feedURL: Self.aardvarkFeed, title: "Aardvark Twin"),
            SubscriptionRecord(feedURL: Self.zephyrFeed, title: "Zephyr")
        ]

        let choices = PlaylistOrganizerShowChoiceBuilder.make(
            subscriptions: subscriptions,
            podcastCache: { _ in nil },
            episodeCount: { _ in 5 }
        )

        #expect(choices.map(\.podcastID) == [Self.aardvarkFeed, Self.middleFeed, Self.zephyrFeed])
        #expect(choices.map(\.title) == ["Aardvark", "Middle", "Zephyr"])
        #expect(choices.map(\.id) == choices.map(\.podcastID))
    }

    @Test("A show becomes eligible at the minimum episode count")
    func eligibilityFollowsTheMinimum() {
        let minimum = PlaylistOrganizerFeatureFlags.minimumEpisodeCount
        let counts = [Self.aardvarkFeed: minimum - 1, Self.zephyrFeed: minimum]

        let choices = PlaylistOrganizerShowChoiceBuilder.make(
            subscriptions: [
                SubscriptionRecord(feedURL: Self.aardvarkFeed, title: "Aardvark"),
                SubscriptionRecord(feedURL: Self.zephyrFeed, title: "Zephyr")
            ],
            podcastCache: { _ in nil },
            episodeCount: { counts[$0] ?? 0 }
        )

        #expect(choices.map(\.episodeCount) == [minimum - 1, minimum])
        #expect(choices.map(\.isEligible) == [false, true])
        #expect(!Self.choice(episodeCount: 0).isEligible)
    }

    @Test("The podcast cache's title, author and artwork win; the subscription's fill in without a cache")
    func cacheFirstThenSubscription() throws {
        let cacheArtwork = "https://example.com/cache-art.png"
        let preview = try Self.makePreview(forArtworkURL: cacheArtwork)
        let cached = PodcastCacheSnapshot(
            feedURL: Self.aardvarkFeed,
            title: "Aardvark (Cache)",
            author: "Cache Author",
            summary: nil,
            websiteURL: nil,
            artworkURL: cacheArtwork,
            artworkPreview: preview,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let subscriptions = [
            SubscriptionRecord(
                feedURL: Self.aardvarkFeed,
                title: "Aardvark",
                author: "Subscription Author",
                artworkURL: "https://example.com/subscription-art.png"
            ),
            SubscriptionRecord(
                feedURL: Self.zephyrFeed,
                title: "Zephyr",
                author: "Zephyr Author",
                artworkURL: "https://example.com/zephyr-art.png"
            )
        ]

        let choices = PlaylistOrganizerShowChoiceBuilder.make(
            subscriptions: subscriptions,
            podcastCache: { $0 == Self.aardvarkFeed ? cached : nil },
            episodeCount: { _ in 4 }
        )

        let fromCache = try #require(choices.first)
        #expect(fromCache.title == "Aardvark (Cache)")
        #expect(fromCache.author == "Cache Author")
        #expect(fromCache.artworkURL == cacheArtwork)
        #expect(fromCache.artworkPreview == preview)

        let fromSubscription = try #require(choices.last)
        #expect(fromSubscription.title == "Zephyr")
        #expect(fromSubscription.author == "Zephyr Author")
        #expect(fromSubscription.artworkURL == "https://example.com/zephyr-art.png")
        #expect(fromSubscription.artworkPreview == nil)
    }

    @Test("Matching ignores case and diacritics on title and author, and blank queries match every show")
    func matchesTitleAndAuthorLoosely() {
        let choice = Self.choice(title: "Café Stories", author: "Renée Night")

        #expect(choice.matches("cafe"))
        #expect(choice.matches("CAFÉ STO"))
        #expect(choice.matches("renee"))
        #expect(choice.matches("  night "))
        #expect(!choice.matches("history"))
        #expect(choice.matches(""))
        #expect(choice.matches("  "))

        let anonymous = Self.choice(title: "Harbor Walks", author: nil)
        #expect(anonymous.matches("harbor"))
        #expect(!anonymous.matches("renee"))
    }

    @Test("Episode counts inflect")
    func episodeCountInflects() {
        #expect(PlaylistOrganizerCopy.episodeCount(1) == "1 episode")
        #expect(PlaylistOrganizerCopy.episodeCount(4) == "4 episodes")
    }

    @Test("The organizer subtitle names its show and falls back to Beta")
    func organizerSubtitle() {
        #expect(PlaylistOrganizerCopy.subtitle(showTitle: "Harbor Walks") == "Harbor Walks · Beta")
        #expect(PlaylistOrganizerCopy.subtitle(showTitle: nil) == "Beta")
        #expect(PlaylistOrganizerCopy.subtitle(showTitle: " ") == "Beta")
    }

    private static func choice(
        title: String = "Harbor Walks",
        author: String? = nil,
        episodeCount: Int = 4
    ) -> PlaylistOrganizerShowChoice {
        PlaylistOrganizerShowChoice(
            podcastID: "https://example.com/harbor.xml",
            title: title,
            author: author,
            artworkURL: nil,
            artworkPreview: nil,
            episodeCount: episodeCount
        )
    }

    private static func makePreview(forArtworkURL artworkURL: String) throws -> ArtworkPreview {
        let canonicalKey = try #require(ArtworkPreview.canonicalArtworkURLKey(for: artworkURL))
        return try #require(
            ArtworkPreview(
                version: ArtworkPreview.currentVersion,
                canonicalArtworkURLKey: canonicalKey,
                sourceHash: "hash-\(artworkURL)",
                pixelWidth: 8,
                pixelHeight: 8,
                rgbData: Data(repeating: 0x40, count: ArtworkPreview.requiredRGBByteCount(width: 8, height: 8))
            )
        )
    }
}
