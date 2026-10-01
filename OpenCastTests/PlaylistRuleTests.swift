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
        status: .inProgress,
        downloadedOnly: true,
        minimumMinutes: 15,
        maximumMinutes: 45,
        maximumAgeDays: 30,
        sortOrder: .oldestFirst,
        limit: 10
    )

    // MARK: - Coding

    @Test("The default rule is unplayed, all shows, any length and age, newest first, 25 episodes")
    func defaultRule() {
        let rule = PlaylistRule.default

        #expect(rule.version == 1)
        #expect(rule.podcastIDs == nil)
        #expect(rule.status == .unplayed)
        #expect(!rule.downloadedOnly)
        #expect(rule.minimumMinutes == nil)
        #expect(rule.maximumMinutes == nil)
        #expect(rule.maximumAgeDays == nil)
        #expect(rule.sortOrder == .newestFirst)
        #expect(rule.limit == 25)
        #expect(rule.normalized() == rule)
    }

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
                + #""sortOrder":"oldestFirst","status":"inProgress","version":1}"#
        )
        #expect(!Self.everyClause.encodedJSON().contains(#"\/"#))
    }

    @Test("Equal rules encode identically whatever order their shows were toggled in")
    func toggleOrderDoesNotChangeEncoding() {
        let forward = PlaylistRule(podcastIDs: [Self.alphaID, Self.bravoID]).normalized()
        let backward = PlaylistRule(podcastIDs: [Self.bravoID, Self.alphaID, Self.bravoID]).normalized()

        #expect(forward == backward)
        #expect(forward.encodedJSON() == backward.encodedJSON())
    }

    @Test("A No Limit rule omits the limit and decodes back to No Limit, not the default 25")
    func noLimitRoundTrips() throws {
        var rule = PlaylistRule.default
        rule.limit = nil

        let json = rule.encodedJSON()
        let decoded = try #require(PlaylistRule.decode(json))

        #expect(!json.contains("limit"))
        #expect(decoded.limit == nil)
        #expect(decoded == rule)
        #expect(decoded != .default)
    }

    @Test("A bare version 1 object decodes to unplayed, all shows, newest first, no limit")
    func bareVersionDecodesToPropertyDefaults() throws {
        let rule = try #require(PlaylistRule.decode(#"{"version":1}"#))

        #expect(rule == PlaylistRule())
        #expect(rule.status == .unplayed)
        #expect(rule.podcastIDs == nil)
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
            #"{"version":0}"#,
            #"{"version":"1"}"#,
            #"{"status":"played"}"#,
            #"{"version":1,"status":"someday"}"#,
            #"{"version":1,"sortOrder":"loudestFirst"}"#,
            #"{"version":1,"limit":"ten"}"#,
            "not json",
            "",
            "[1]",
            "1",
            #""rule""#,
            "null"
        ]
    )
    func unreadableRulesDecodeToNil(json: String) {
        #expect(PlaylistRule.decode(json) == nil)
    }

    @Test("Decoding nil yields nil")
    func decodingNilYieldsNil() {
        #expect(PlaylistRule.decode(nil) == nil)
    }

    @Test("Decoding normalizes the stored rule")
    func decodeNormalizes() throws {
        let json = #"{"version":1,"status":"downloaded","podcastIDs":[],"limit":0,"minimumMinutes":-5,"maximumAgeDays":-1}"#

        let rule = try #require(PlaylistRule.decode(json))

        #expect(rule.status == .all)
        #expect(rule.downloadedOnly)
        #expect(rule.podcastIDs == nil)
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

    @Test("Normalizing moves the Downloaded filter into its own clause and keeps other statuses")
    func normalizedMovesDownloadedStatus() {
        let downloaded = PlaylistRule(status: .downloaded).normalized()

        #expect(downloaded.status == .all)
        #expect(downloaded.downloadedOnly)
        for status in PlaylistRule.statusOptions {
            let rule = PlaylistRule(status: status, downloadedOnly: true).normalized()
            #expect(rule.status == status)
            #expect(rule.downloadedOnly)
        }
        let otherStatuses = PodcastEpisodeFilter.allCases.filter { $0 != .downloaded }
        #expect(otherStatuses.allSatisfy { !PlaylistRule(status: $0).normalized().downloadedOnly })
    }

    @Test("Only All Episodes skips played state")
    func readsProgress() {
        #expect(!PlaylistRule(status: .all).readsProgress)
        #expect(!PlaylistRule(status: .all, downloadedOnly: true).readsProgress)
        #expect(PlaylistRule(status: .unplayed).readsProgress)
        #expect(PlaylistRule(status: .inProgress).readsProgress)
        #expect(PlaylistRule(status: .played).readsProgress)
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

    @Test("The Episodes chip names the status and adds Downloaded for Downloaded Only")
    func episodesTitles() {
        #expect(PlaylistRule(status: .unplayed).episodesTitle == "Unplayed")
        #expect(PlaylistRule(status: .all).episodesTitle == "All Episodes")
        #expect(PlaylistRule(status: .inProgress).episodesTitle == "In Progress")
        #expect(PlaylistRule(status: .played).episodesTitle == "Played")
        #expect(PlaylistRule(status: .all, downloadedOnly: true).episodesTitle == "Downloaded")
        #expect(PlaylistRule(status: .unplayed, downloadedOnly: true).episodesTitle == "Unplayed, Downloaded")
        #expect(PlaylistRule(status: .played, downloadedOnly: true).episodesTitle == "Played, Downloaded")

        #expect(PlaylistRule(status: .unplayed).episodesSystemImage == "circle")
        #expect(PlaylistRule(status: .all).episodesSystemImage == "line.3.horizontal.decrease.circle")
        #expect(PlaylistRule(status: .all, downloadedOnly: true).episodesSystemImage == "arrow.down.circle")
        #expect(PlaylistRule(status: .played, downloadedOnly: true).episodesSystemImage == "checkmark.circle")
        #expect(PlaylistRule.statusOptions.map(\.title) == ["All Episodes", "Unplayed", "In Progress", "Played"])
    }

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

    @Test("The Sort chip reads the sort order's title")
    func sortTitles() {
        #expect(PlaylistRule.default.sortTitle == "Newest First")
        #expect(PlaylistRule(sortOrder: .oldestFirst).sortTitle == "Oldest First")
        #expect(PlaylistRule(sortOrder: .longestFirst).sortTitle == "Longest First")
        #expect(PlaylistRule(sortOrder: .shortestFirst).sortTitle == "Shortest First")
    }

    @Test("Length titles read minutes below an hour and hours from an hour, for presets and other bounds")
    func lengthTitles() {
        let cases: [(minimum: Int?, maximum: Int?, title: String)] = [
            (nil, nil, "Any Length"),
            (nil, 45, "Under 45 min"),
            (nil, 60, "Under 1 hr"),
            (nil, 90, "Under 1 hr 30 min"),
            (30, nil, "Over 30 min"),
            (60, nil, "Over 1 hr"),
            (120, nil, "Over 2 hr"),
            (15, 45, "15–45 min"),
            (30, 90, "30 min–1 hr 30 min"),
            (60, 120, "1 hr–2 hr")
        ]

        for (minimum, maximum, title) in cases {
            #expect(PlaylistRule.lengthTitle(minimumMinutes: minimum, maximumMinutes: maximum) == title)
            #expect(PlaylistRule(minimumMinutes: minimum, maximumMinutes: maximum).lengthTitle == title)
        }
    }

    @Test("Spoken length titles spell out minutes and hours in agreeing number")
    func lengthAccessibilityTitles() {
        let cases: [(minimum: Int?, maximum: Int?, title: String)] = [
            (nil, nil, "Any Length"),
            (nil, 45, "Under 45 minutes"),
            (nil, 1, "Under 1 minute"),
            (nil, 61, "Under 1 hour 1 minute"),
            (60, nil, "Over 1 hour"),
            (120, nil, "Over 2 hours"),
            (15, 45, "15 to 45 minutes"),
            (30, 90, "30 minutes to 1 hour 30 minutes")
        ]

        for (minimum, maximum, title) in cases {
            #expect(PlaylistRule.lengthAccessibilityTitle(minimumMinutes: minimum, maximumMinutes: maximum) == title)
            #expect(PlaylistRule(minimumMinutes: minimum, maximumMinutes: maximum).lengthAccessibilityTitle == title)
        }
    }

    @Test("Age titles read Any Time, Last Year, or the day count in agreeing number")
    func ageTitles() {
        #expect(PlaylistRule.ageTitle(maximumAgeDays: nil) == "Any Time")
        #expect(PlaylistRule.ageTitle(maximumAgeDays: 365) == "Last Year")
        #expect(PlaylistRule.ageTitle(maximumAgeDays: 7) == "Last 7 days")
        #expect(PlaylistRule.ageTitle(maximumAgeDays: 1) == "Last 1 day")
        #expect(PlaylistRule.ageTitle(maximumAgeDays: 10) == "Last 10 days")
        #expect(PlaylistRule(maximumAgeDays: 30).ageTitle == "Last 30 days")
        #expect(
            PlaylistRule.agePresets.map { PlaylistRule.ageTitle(maximumAgeDays: $0) }
                == ["Any Time", "Last 7 days", "Last 14 days", "Last 30 days", "Last 90 days", "Last Year"]
        )
    }

    @Test("Limit titles read No Limit or the episode count in agreeing number")
    func limitTitles() {
        #expect(PlaylistRule.limitTitle(limit: nil) == "No Limit")
        #expect(PlaylistRule.limitTitle(limit: 1) == "1 episode")
        #expect(PlaylistRule.limitTitle(limit: 25) == "25 episodes")
        #expect(PlaylistRule.default.limitTitle == "25 episodes")
        #expect(PlaylistRule().limitTitle == "No Limit")
        #expect(
            PlaylistRule.limitPresets.map { PlaylistRule.limitTitle(limit: $0) }
                == ["10 episodes", "25 episodes", "50 episodes", "100 episodes", "No Limit"]
        )
    }

    // MARK: - Length presets

    @Test("Length presets keep their order, bounds and titles")
    func lengthPresets() {
        let presets = PlaylistRuleLengthPreset.allCases

        #expect(presets == [.any, .under15, .under30, .under45, .under60, .over30, .over60, .over120])
        #expect(presets.map(\.minimumMinutes) == [nil, nil, nil, nil, nil, 30, 60, 120])
        #expect(presets.map(\.maximumMinutes) == [nil, 15, 30, 45, 60, nil, nil, nil])
        #expect(
            presets.map(\.title) == [
                "Any Length", "Under 15 min", "Under 30 min", "Under 45 min",
                "Under 1 hr", "Over 30 min", "Over 1 hr", "Over 2 hr"
            ]
        )
        for preset in presets {
            let rule = PlaylistRule(minimumMinutes: preset.minimumMinutes, maximumMinutes: preset.maximumMinutes)
            #expect(rule.lengthTitle == preset.title)
        }
    }

    @Test("A preset matches its own bounds and nothing matches a non-preset pair")
    func lengthPresetMatching() {
        for preset in PlaylistRuleLengthPreset.allCases {
            #expect(
                PlaylistRuleLengthPreset.matching(
                    minimumMinutes: preset.minimumMinutes,
                    maximumMinutes: preset.maximumMinutes
                ) == preset
            )
        }
        #expect(PlaylistRuleLengthPreset.matching(minimumMinutes: 15, maximumMinutes: 45) == nil)
        #expect(PlaylistRuleLengthPreset.matching(minimumMinutes: nil, maximumMinutes: 20) == nil)
        #expect(PlaylistRuleLengthPreset.matching(minimumMinutes: 45, maximumMinutes: nil) == nil)
        #expect(PlaylistRuleLengthPreset.matching(minimumMinutes: 30, maximumMinutes: 30) == nil)
    }
}
