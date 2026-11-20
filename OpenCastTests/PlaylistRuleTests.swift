import Foundation
import Testing
@testable import OpenCast

@Suite("Playlist rule")
struct PlaylistRuleTests {
    private static let alphaID = "https://example.com/alpha.xml"
    private static let bravoID = "https://example.com/bravo.xml"
    private static let charlieID = "https://example.com/charlie.xml"

    private static let everyClause = PlaylistRule(
        podcastIDs: [alphaID, bravoID],
        priorityPodcastIDs: [bravoID],
        status: .inProgress,
        downloadedOnly: true,
        minimumMinutes: 15,
        maximumMinutes: 45,
        maximumAgeDays: 30,
        sortOrder: .oldestFirst,
        limit: 10
    )

    // MARK: - Coding

    @Test("A rule with every clause set survives an encode and decode unchanged")
    func roundTrip() throws {
        let decoded = try #require(PlaylistRule.decode(Self.everyClause.encodedJSON()))
        let decodedDefault = try #require(PlaylistRule.decode(PlaylistRule.default.encodedJSON()))

        #expect(decoded == Self.everyClause)
        #expect(decodedDefault == .default)
    }

    @Test("Encoding sorts keys, leaves slashes unescaped and omits unset clauses")
    func encodedJSONIsDeterministic() {
        #expect(
            PlaylistRule.default.encodedJSON()
                == #"{"downloadedOnly":false,"limit":25,"sortOrder":"newestFirst","status":"unplayed","version":1}"#
        )
        #expect(
            Self.everyClause.encodedJSON()
                == #"{"downloadedOnly":true,"limit":10,"maximumAgeDays":30,"maximumMinutes":45,"minimumMinutes":15,"#
                + #""podcastIDs":["https://example.com/alpha.xml","https://example.com/bravo.xml"],"#
                + #""priorityPodcastIDs":["https://example.com/bravo.xml"],"#
                + #""sortOrder":"oldestFirst","status":"inProgress","version":1}"#
        )
        #expect(!Self.everyClause.encodedJSON().contains(#"\/"#))
    }

    @Test("A bare version 1 object decodes to unplayed, all shows, newest first, no limit")
    func bareVersionDecodesToPropertyDefaults() throws {
        let rule = try #require(PlaylistRule.decode(#"{"version":1}"#))

        #expect(rule == PlaylistRule())
        #expect(rule.status == .unplayed)
        #expect(rule.podcastIDs == nil)
        #expect(rule.priorityPodcastIDs == nil)
        #expect(!rule.downloadedOnly)
        #expect(rule.minimumMinutes == nil)
        #expect(rule.maximumMinutes == nil)
        #expect(rule.maximumAgeDays == nil)
        #expect(rule.sortOrder == .newestFirst)
        #expect(rule.limit == nil)
    }

    @Test(
        "A missing, newer-version, versionless, malformed or non-object rule is unreadable",
        arguments: [
            #"{"version":2}"#,
            #"{"status":"played"}"#,
            #"{"version":1,"status":"someday"}"#,
            "not json",
            "",
            "[1]"
        ]
    )
    func unreadableRulesDecodeToNil(json: String) {
        #expect(PlaylistRule.decode(json) == nil)
    }

    @Test("Decoding normalizes the stored rule")
    func decodeNormalizes() throws {
        let json = #"{"version":1,"status":"downloaded","podcastIDs":[],"priorityPodcastIDs":[],"limit":0,"minimumMinutes":-5,"maximumAgeDays":-1}"#

        let rule = try #require(PlaylistRule.decode(json))

        #expect(rule.status == .all)
        #expect(rule.downloadedOnly)
        #expect(rule.podcastIDs == nil)
        #expect(rule.priorityPodcastIDs == nil)
        #expect(rule.limit == nil)
        #expect(rule.minimumMinutes == nil)
        #expect(rule.maximumAgeDays == nil)
    }

    // MARK: - Normalization

    @Test("Normalizing deduplicates and sorts show IDs and turns an empty list into all shows")
    func normalizedShowIDs() {
        let listed = PlaylistRule(podcastIDs: [Self.charlieID, Self.alphaID, Self.charlieID, Self.bravoID])

        #expect(listed.normalized().podcastIDs == [Self.alphaID, Self.bravoID, Self.charlieID])
        #expect(PlaylistRule(podcastIDs: []).normalized().podcastIDs == nil)
        #expect(PlaylistRule(podcastIDs: nil).normalized().podcastIDs == nil)
    }

    @Test("Normalizing deduplicates priority IDs in rank order and keeps only the listed shows")
    func normalizedPriorityIDsKeepOrderAndRespectShows() {
        let ranked = [Self.charlieID, Self.alphaID, Self.charlieID, Self.bravoID]

        #expect(PlaylistRule(priorityPodcastIDs: ranked).normalized().priorityPodcastIDs == [Self.charlieID, Self.alphaID, Self.bravoID])
        #expect(
            PlaylistRule(podcastIDs: [Self.bravoID, Self.alphaID], priorityPodcastIDs: ranked)
                .normalized().priorityPodcastIDs == [Self.alphaID, Self.bravoID]
        )
        #expect(PlaylistRule(podcastIDs: [Self.alphaID], priorityPodcastIDs: [Self.bravoID]).normalized().priorityPodcastIDs == nil)
        // An empty show list is All Shows, so the priority survives.
        #expect(PlaylistRule(podcastIDs: [], priorityPodcastIDs: [Self.alphaID]).normalized().priorityPodcastIDs == [Self.alphaID])
        #expect(PlaylistRule(priorityPodcastIDs: []).normalized().priorityPodcastIDs == nil)
    }

    @Test("Normalizing drops a zero or negative limit and negative lengths and ages")
    func normalizedDropsOutOfRangeNumbers() {
        #expect(PlaylistRule(limit: 0).normalized().limit == nil)
        #expect(PlaylistRule(limit: -3).normalized().limit == nil)
        #expect(PlaylistRule(limit: 1).normalized().limit == 1)
        #expect(PlaylistRule(minimumMinutes: -1).normalized().minimumMinutes == nil)
        #expect(PlaylistRule(maximumMinutes: -30).normalized().maximumMinutes == nil)
        #expect(PlaylistRule(maximumAgeDays: -7).normalized().maximumAgeDays == nil)
        #expect(PlaylistRule(minimumMinutes: 30, maximumMinutes: 60).normalized().minimumMinutes == 30)
        #expect(PlaylistRule(minimumMinutes: 30, maximumMinutes: 60).normalized().maximumMinutes == 60)
        #expect(PlaylistRule(maximumAgeDays: 14).normalized().maximumAgeDays == 14)
    }

    @Test("Replacing a moved show swaps it in place, normalizes, and is nil when nothing moved")
    func replacingPodcastIDs() {
        let rule = PlaylistRule(podcastIDs: [Self.bravoID, Self.alphaID], status: .played, limit: 10)

        let replaced = rule.replacingPodcastIDs(where: { $0 == Self.alphaID }, with: Self.charlieID)
        #expect(replaced?.podcastIDs == [Self.bravoID, Self.charlieID])
        #expect(replaced?.status == .played)
        #expect(replaced?.limit == 10)
        #expect(rule.replacingPodcastIDs(where: { $0 == Self.charlieID }, with: Self.alphaID) == nil)
        #expect(PlaylistRule().replacingPodcastIDs(where: { _ in true }, with: Self.alphaID) == nil)
        #expect(
            PlaylistRule(podcastIDs: [Self.alphaID, Self.bravoID])
                .replacingPodcastIDs(where: { $0 == Self.alphaID }, with: Self.bravoID)?
                .podcastIDs == [Self.bravoID]
        )
    }

    // MARK: - Titles

    @Test("The Shows chip counts only listed shows that are still subscribed, in agreeing number")
    func showsTitles() {
        let subscribed: Set = [Self.alphaID, Self.bravoID, Self.charlieID]

        #expect(PlaylistRule().showsTitle(subscribedPodcastIDs: subscribed) == "All Shows")
        #expect(PlaylistRule().showsTitle(subscribedPodcastIDs: []) == "All Shows")
        #expect(PlaylistRule(podcastIDs: [Self.alphaID]).showsTitle(subscribedPodcastIDs: subscribed) == "1 Show")
        #expect(
            PlaylistRule(podcastIDs: [Self.alphaID, Self.bravoID, Self.charlieID])
                .showsTitle(subscribedPodcastIDs: subscribed) == "3 Shows"
        )
        #expect(
            PlaylistRule(podcastIDs: [Self.alphaID, "https://example.com/departed.xml"])
                .showsTitle(subscribedPodcastIDs: subscribed) == "1 Show"
        )
        #expect(
            PlaylistRule(podcastIDs: ["https://example.com/departed.xml"])
                .showsTitle(subscribedPodcastIDs: subscribed) == "No Shows"
        )
    }

    @Test("The Priority chip counts only ranked shows that are still subscribed, in agreeing number")
    func priorityTitles() {
        let subscribed: Set = [Self.alphaID, Self.bravoID, Self.charlieID]
        let departedID = "https://example.com/departed.xml"

        #expect(PlaylistRule().priorityTitle(subscribedPodcastIDs: subscribed) == "No Priority")
        #expect(PlaylistRule(priorityPodcastIDs: [Self.alphaID]).priorityTitle(subscribedPodcastIDs: subscribed) == "1 Show First")
        #expect(
            PlaylistRule(priorityPodcastIDs: [Self.alphaID, Self.bravoID])
                .priorityTitle(subscribedPodcastIDs: subscribed) == "2 Shows First"
        )
        #expect(PlaylistRule(priorityPodcastIDs: [departedID]).priorityTitle(subscribedPodcastIDs: subscribed) == "No Priority")
        #expect(
            PlaylistRule(priorityPodcastIDs: [Self.alphaID, departedID])
                .priorityTitle(subscribedPodcastIDs: subscribed) == "1 Show First"
        )
    }

    @Test(
        "Length titles read minutes below an hour and hours from an hour, for presets and other bounds",
        arguments: [
            (nil, nil, "Any Length"),
            (nil, 45, "Under 45 min"),
            (nil, 60, "Under 1 hr"),
            (nil, 90, "Under 1 hr 30 min"),
            (60, nil, "Over 1 hr"),
            (15, 45, "15–45 min"),
            (30, 90, "30 min–1 hr 30 min")
        ] as [(Int?, Int?, String)]
    )
    func lengthTitles(minimum: Int?, maximum: Int?, title: String) {
        #expect(PlaylistRule.lengthTitle(minimumMinutes: minimum, maximumMinutes: maximum) == title)
        #expect(PlaylistRule(minimumMinutes: minimum, maximumMinutes: maximum).lengthTitle == title)
    }
}
