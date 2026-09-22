import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Library new-episode rules")
struct LibraryNewEpisodeRulesTests {
    private static let asOf = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    @Test("The recency window is thirty days")
    func recencyWindowIsThirtyDays() {
        #expect(LibraryNewEpisodeRules.recencyWindow == 30 * Self.day)
    }

    @Test("A recent follow starts the range at the subscription instant, inclusive")
    func recentFollowStartsAtSubscription() throws {
        let subscribedAt = Self.asOf.addingTimeInterval(-5 * Self.day)

        let range = try #require(
            LibraryNewEpisodeRules.eligibleReleaseDates(subscribedAt: subscribedAt, asOf: Self.asOf)
        )

        #expect(range == subscribedAt...Self.asOf)
        #expect(range.contains(subscribedAt))
        // Recent, but released before the show was followed.
        #expect(!range.contains(subscribedAt.addingTimeInterval(-1)))
    }

    @Test("A long-standing follow starts the range at the recency window, inclusive")
    func longStandingFollowStartsAtWindow() throws {
        let windowStart = Self.asOf.addingTimeInterval(-30 * Self.day)

        let range = try #require(
            LibraryNewEpisodeRules.eligibleReleaseDates(
                subscribedAt: Self.asOf.addingTimeInterval(-90 * Self.day),
                asOf: Self.asOf
            )
        )

        #expect(range == windowStart...Self.asOf)
        #expect(range.contains(windowStart))
        #expect(!range.contains(windowStart.addingTimeInterval(-1)))
    }

    @Test("A release at the reference instant counts; a later one does not")
    func upperBoundIsTheReferenceInstant() throws {
        let range = try #require(
            LibraryNewEpisodeRules.eligibleReleaseDates(
                subscribedAt: Self.asOf.addingTimeInterval(-90 * Self.day),
                asOf: Self.asOf
            )
        )

        #expect(range.contains(Self.asOf))
        #expect(!range.contains(Self.asOf.addingTimeInterval(1)))
    }

    @Test("A follow after the reference instant has no eligible range")
    func followAfterReferenceInstantIsNil() throws {
        #expect(
            LibraryNewEpisodeRules.eligibleReleaseDates(
                subscribedAt: Self.asOf.addingTimeInterval(1),
                asOf: Self.asOf
            ) == nil
        )

        // Following at the reference instant itself leaves just that instant.
        let range = try #require(
            LibraryNewEpisodeRules.eligibleReleaseDates(subscribedAt: Self.asOf, asOf: Self.asOf)
        )
        #expect(range == Self.asOf...Self.asOf)
    }
}
