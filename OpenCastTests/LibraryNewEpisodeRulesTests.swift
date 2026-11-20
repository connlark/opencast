import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Library new-episode rules")
struct LibraryNewEpisodeRulesTests {
    private static let asOf = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A follow after the reference instant has no eligible range")
    func followAfterReferenceInstantIsNil() throws {
        #expect(
            LibraryNewEpisodeRules.eligibleReleaseDates(
                subscribedAt: Self.asOf.addingTimeInterval(1),
                asOf: Self.asOf
            ) == nil
        )

        let range = try #require(
            LibraryNewEpisodeRules.eligibleReleaseDates(subscribedAt: Self.asOf, asOf: Self.asOf)
        )
        #expect(range == Self.asOf...Self.asOf)
    }
}
