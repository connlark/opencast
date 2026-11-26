import Foundation
import OpenCastCore
import Testing

struct FeedDigestTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    @Test("Episodes run newest first by date, ties and then undated ones in feed order", arguments: [
        ([("A", "2026-09-01T09:00:00-07:00"), ("X", nil), ("B", "2026-10-01T09:00:00-07:00"), ("Y", nil),
          ("C", "2026-11-01T09:00:00-08:00"), ("Z", nil)], ["C", "B", "A", "X", "Y", "Z"], "C", "2026-09-01T09:00:00-07:00"),
        ([("A", "2026-11-01T09:00:00-08:00"), ("B", "2026-11-01T09:00:00-08:00"), ("C", "2026-10-01T09:00:00-07:00")],
         ["A", "B", "C"], "A", "2026-10-01T09:00:00-07:00"),
        ([("X", nil), ("Y", nil)], ["X", "Y"], "X", nil)
    ] as [([(String, String?)], [String], String, String?)])
    func episodes(feed: [(String, String?)], titles: [String], newest: String, oldest: String?) async throws {
        let episodes = try feed.map { title, published in (title, try published.map(date)) }
        let digest = try await digest(episodes, asOf: date("2026-11-23T12:00:00-08:00"))
        #expect(digest.episodes.map(\.title) == titles)
        #expect(digest.newestEpisode?.title == newest)
        #expect(try digest.oldestPublishedAt == oldest.map(date))
    }

    @Test("Monthly counts cover the caller's twelve calendar months across a year boundary")
    func monthlyCounts() async throws {
        let digest = try await digest([
            ("Before the window", date("2026-03-01T07:30:00Z")),
            ("First month", date("2026-03-01T08:30:00Z")),
            ("December", date("2026-12-31T23:00:00-08:00")),
            ("Still December here", date("2027-01-01T07:30:00Z")),
            ("January", date("2027-01-01T08:30:00Z")),
            ("Later this month", date("2027-02-27T09:00:00-08:00")),
            ("Next month", date("2027-03-01T09:00:00-08:00"))
        ], asOf: date("2027-02-10T12:00:00-08:00"))
        #expect(digest.monthlyEpisodeCounts == [1, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1])
    }

    @Test("A cadence needs four release days and a median gap in its band shared by most gaps", arguments: [
        ([0, 1, 2, 3, 4, 7], .daily), ([0, 2, 4, 6], nil),
        ([0, 6, 12, 18], .weekly), ([0, 8, 16, 24], .weekly), ([0, 5, 10, 15], nil), ([0, 9, 18, 27], nil),
        ([16, 10, 3, -5], .weekly),
        ([0, 13, 26, 39], .everyTwoWeeks), ([0, 15, 30, 45], .everyTwoWeeks), ([0, 12, 24, 36], nil), ([0, 16, 32, 48], nil),
        ([0, 27, 54, 81], .monthly), ([0, 36, 72, 108], .monthly), ([0, 26, 52, 78], nil), ([0, 37, 74, 111], nil),
        ([-40, 0, 7, 14], nil), ([0, 1, 8, 38], nil), ([0, 7, 14, 44, 74], nil)
    ] as [([Int], FeedCadence?)])
    func cadence(daysAgo: [Int], cadence: FeedCadence?) async throws {
        #expect(try await digest(daysAgo: daysAgo).cadence == cadence)
    }

    @Test("Episodes at both ends of one local day are one release day")
    func oneReleaseDay() async throws {
        let digest = try await digest([
            ("", date("2025-11-24T12:00:00-08:00")), ("", date("2025-12-01T12:00:00-08:00")),
            ("", date("2025-12-08T00:30:00-08:00")), ("", date("2025-12-08T23:30:00-08:00")),
            ("", date("2025-12-15T12:00:00-08:00"))
        ], asOf: date("2026-11-23T12:00:00-08:00"))
        #expect(digest.cadence == nil)
    }

    @Test("A show is stopped after the longer of 60 days and three median gaps since its newest episode", arguments: [
        ([60, 67, 74, 81], false), ([61, 68, 75, 82], true),
        ([90, 120, 150, 180], false), ([91, 121, 151, 181], true),
        ([60], false), ([70, 190], false), ([61, 71, 111], true), ([400], true),
        ([-40, 100, 107, 114], false), ([-10], false), ([nil], false)
    ] as [([Int?], Bool)])
    func stopped(daysAgo: [Int?], isStopped: Bool) async throws {
        #expect(try await digest(daysAgo: daysAgo).isStopped == isStopped)
    }

    private func digest(daysAgo: [Int?]) async throws -> FeedDigest {
        let reference = try date("2026-11-23T12:00:00-08:00")
        let episodes = daysAgo.map { ("Episode", $0.flatMap { calendar.date(byAdding: .day, value: -$0, to: reference) }) }
        return try await digest(episodes, asOf: reference)
    }

    private func digest(_ items: [(String, Date?)], asOf reference: Date) async throws -> FeedDigest {
        let podcastID = PodcastID(rawValue: "https://example.com/feed.xml")
        let episodes = items.map { title, date in
            Episode(id: EpisodeID(rawValue: title), podcastID: podcastID, podcastTitle: "Show", title: title,
                    publishedAt: date)
        }
        let feed = try PreparedFeed(snapshot: FeedSnapshot(
            podcast: Podcast(id: podcastID, feedURL: URL(string: podcastID.rawValue)!, title: "Show"), episodes: episodes))
        return try await feed.digest(asOf: reference, timeZone: calendar.timeZone)
    }

    private func date(_ iso8601: String) throws -> Date {
        try Date(iso8601, strategy: .iso8601)
    }
}
