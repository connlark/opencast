import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Library sort order and layout preference")
struct LibrarySortOrderTests {
    private static let referenceDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("Persisted raw values stay stable")
    func persistedRawValuesStayStable() {
        #expect(LibraryLayoutPreference.automatic.rawValue == "automatic")
        #expect(LibraryLayoutPreference.list.rawValue == "list")
        #expect(LibraryLayoutPreference.grid.rawValue == "grid")
        #expect(LibrarySortOrder.title.rawValue == "title")
        #expect(LibrarySortOrder.recentEpisodes.rawValue == "recentEpisodes")
    }

    @Test("Automatic resolves to a grid in regular width and a list in compact width")
    func automaticFollowsWidthClass() {
        #expect(LibraryLayoutPreference.automatic.resolved(isRegularWidth: true) == .grid)
        #expect(LibraryLayoutPreference.automatic.resolved(isRegularWidth: false) == .list)
    }

    @Test("Explicit layouts ignore the width class", arguments: [true, false])
    func explicitLayoutsIgnoreWidthClass(isRegularWidth: Bool) {
        #expect(LibraryLayoutPreference.list.resolved(isRegularWidth: isRegularWidth) == .list)
        #expect(LibraryLayoutPreference.grid.resolved(isRegularWidth: isRegularWidth) == .grid)
    }

    @Test("Title keeps the store's order and ignores release dates")
    func titlePassesThroughStoreOrder() {
        // Deliberately neither alphabetical nor date ordered.
        let zulu = SubscriptionRecord(feedURL: "https://example.com/zulu.xml", title: "Zulu Show")
        let alpha = SubscriptionRecord(feedURL: "https://example.com/alpha.xml", title: "Alpha Show")
        let mike = SubscriptionRecord(feedURL: "https://example.com/mike.xml", title: "Mike Show")
        let subscriptions = [zulu, alpha, mike]
        let releaseDates = [
            alpha.feedURL: Self.daysAgo(1),
            zulu.feedURL: Self.daysAgo(20)
        ]

        let sorted = LibrarySortOrder.title.sorted(subscriptions, latestReleaseDate: { releaseDates[$0] })

        #expect(sorted.map { ObjectIdentifier($0) } == subscriptions.map { ObjectIdentifier($0) })
    }

    @Test("Recent Episodes puts the newest release first and undated shows last")
    func recentEpisodesOrdersByLatestRelease() {
        let alpha = SubscriptionRecord(feedURL: "https://example.com/alpha.xml", title: "Alpha Show")
        let beta = SubscriptionRecord(feedURL: "https://example.com/beta.xml", title: "Beta Show")
        let gamma = SubscriptionRecord(feedURL: "https://example.com/gamma.xml", title: "Gamma Show")
        let delta = SubscriptionRecord(feedURL: "https://example.com/delta.xml", title: "Delta Show")
        let echo = SubscriptionRecord(feedURL: "https://example.com/echo.xml", title: "Echo Show")
        // Title order is Alpha, Beta, Delta, Echo, Gamma; release order is
        // Beta, Gamma, Alpha, and Delta and Echo have no dated episode.
        let releaseDates = [
            alpha.feedURL: Self.daysAgo(9),
            beta.feedURL: Self.daysAgo(1),
            gamma.feedURL: Self.daysAgo(4)
        ]

        let sorted = LibrarySortOrder.recentEpisodes.sorted(
            [gamma, echo, alpha, delta, beta],
            latestReleaseDate: { releaseDates[$0] }
        )

        #expect(sorted.map(\.title) == ["Beta Show", "Gamma Show", "Alpha Show", "Delta Show", "Echo Show"])
    }

    @Test("Equal release dates fall back to natural title order, then feed address")
    func equalReleaseDatesBreakTiesDeterministically() {
        let showTen = SubscriptionRecord(feedURL: "https://example.com/show-10.xml", title: "Show 10")
        let sameTitleZ = SubscriptionRecord(feedURL: "https://z.example.com/feed.xml", title: "Same Title")
        let showTwo = SubscriptionRecord(feedURL: "https://example.com/show-2.xml", title: "Show 2")
        let sameTitleA = SubscriptionRecord(feedURL: "https://a.example.com/feed.xml", title: "Same Title")
        let subscriptions = [showTen, sameTitleZ, showTwo, sameTitleA]
        let expected = [sameTitleA.feedURL, sameTitleZ.feedURL, showTwo.feedURL, showTen.feedURL]
        let releasedAt = Self.daysAgo(3)

        let sorted = LibrarySortOrder.recentEpisodes.sorted(subscriptions, latestReleaseDate: { _ in releasedAt })
        let reversedInputSorted = LibrarySortOrder.recentEpisodes.sorted(
            Array(subscriptions.reversed()),
            latestReleaseDate: { _ in releasedAt }
        )
        let undatedSorted = LibrarySortOrder.recentEpisodes.sorted(subscriptions, latestReleaseDate: { _ in nil })

        #expect(sorted.map(\.feedURL) == expected)
        #expect(reversedInputSorted.map(\.feedURL) == expected)
        #expect(undatedSorted.map(\.feedURL) == expected)
    }

    @Test("Duplicate subscriptions for one feed sort without losing a record")
    func duplicateFeedURLsSortSafely() {
        let original = SubscriptionRecord(feedURL: "https://example.com/duplicate.xml", title: "Duplicate Show")
        let duplicate = SubscriptionRecord(feedURL: "https://example.com/duplicate.xml", title: "Duplicate Show")
        let newer = SubscriptionRecord(feedURL: "https://example.com/newer.xml", title: "Newer Show")
        let undated = SubscriptionRecord(feedURL: "https://example.com/undated.xml", title: "Undated Show")
        let subscriptions = [original, undated, duplicate, newer]
        let releaseDates = [
            original.feedURL: Self.daysAgo(2),
            newer.feedURL: Self.daysAgo(1)
        ]

        let recent = LibrarySortOrder.recentEpisodes.sorted(subscriptions, latestReleaseDate: { releaseDates[$0] })
        let title = LibrarySortOrder.title.sorted(subscriptions, latestReleaseDate: { releaseDates[$0] })

        #expect(recent.map(\.feedURL) == [newer.feedURL, original.feedURL, original.feedURL, undated.feedURL])
        #expect(Set(recent.map { ObjectIdentifier($0) }) == Set(subscriptions.map { ObjectIdentifier($0) }))
        #expect(title.count == subscriptions.count)
    }

    private static func daysAgo(_ days: Double) -> Date {
        referenceDate.addingTimeInterval(-days * 86_400)
    }
}
