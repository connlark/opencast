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

    private static func choice(title: String, author: String?) -> PlaylistOrganizerShowChoice {
        PlaylistOrganizerShowChoice(
            podcastID: "https://example.com/harbor.xml",
            title: title,
            author: author,
            artworkURL: nil,
            artworkPreview: nil,
            episodeCount: 4
        )
    }
}
