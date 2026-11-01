import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode notes library grouping")
struct EpisodeNotesLibraryGroupingTests {
    @Test("Notes group by episode, the episode note first and then timestamps in order")
    func timelineOrder() throws {
        let late = note("a", "Ninety", at: 90, created: 1)
        let whole = note("a", "Whole", wholeEpisode: true, created: 5)
        let earlyFirst = note("a", "Fifteen first", at: 15, created: 2)
        let earlySecond = note("a", "Fifteen second", at: 15, created: 3)
        let other = note("b", "Other", at: 10, created: 4)
        let groups = EpisodeNotesLibraryGrouping.groups(
            from: [late, other, earlySecond, whole, earlyFirst],
            resolve: { _ in nil },
            matching: "",
            sortedBy: .recent
        )
        #expect(groups.map(\.id) == ["a", "b"])
        let a = try #require(groups.first)
        #expect(a.episodeID == "a")
        #expect(a.notes.map(\.text) == ["Whole", "Fifteen first", "Fifteen second", "Ninety"])
        #expect(a.latestActivity == Date(timeIntervalSince1970: 5))
        #expect(groups.last?.notes.map(\.text) == ["Other"])
    }

    @Test("Header details come from the note, then the episode, then a placeholder")
    func titlePrecedence() throws {
        let stored = note("stored", "Stored", created: 3, show: "Stored Show", title: "Stored Title", podcastID: "feed:stored", artworkURL: "https://example.com/stored.jpg")
        let storedOffline = note("offline", "Offline", created: 2, show: "Offline Show", title: "Offline Title")
        let live = note("live", "Live", created: 1)
        let gone = note("gone", "Gone", created: 0)
        let episodes = [
            "stored": episode("stored", show: "Live Show", title: "Live Title", publishedAt: 100),
            "live": episode("live", show: "Live Show", title: "Live Title", publishedAt: 200),
        ]
        let groups = EpisodeNotesLibraryGrouping.groups(
            from: [stored, storedOffline, live, gone],
            resolve: { episodes[$0] },
            matching: "",
            sortedBy: .recent
        )
        #expect(groups.map(\.id) == ["stored", "offline", "live", "gone"])

        let storedGroup = groups[0]
        #expect(storedGroup.podcastTitle == "Stored Show")
        #expect(storedGroup.episodeTitle == "Stored Title")
        #expect(storedGroup.podcastID == "feed:stored")
        #expect(storedGroup.artworkURL == "https://example.com/stored.jpg")
        #expect(storedGroup.isResolved)
        #expect(storedGroup.publishedAt == Date(timeIntervalSince1970: 100))

        let offlineGroup = groups[1]
        #expect(offlineGroup.podcastTitle == "Offline Show")
        #expect(offlineGroup.episodeTitle == "Offline Title")
        #expect(!offlineGroup.isResolved)
        #expect(offlineGroup.publishedAt == nil)

        let liveGroup = groups[2]
        #expect(liveGroup.podcastTitle == "Live Show")
        #expect(liveGroup.episodeTitle == "Live Title")
        #expect(liveGroup.podcastID == "feed:Live Show")
        #expect(liveGroup.artworkURL == "https://example.com/live.jpg")
        #expect(liveGroup.isResolved)
        #expect(liveGroup.publishedAt == Date(timeIntervalSince1970: 200))

        let goneGroup = groups[3]
        #expect(goneGroup.podcastTitle == "Unknown Show")
        #expect(goneGroup.episodeTitle == "Unknown Episode")
        #expect(goneGroup.podcastID == "")
        #expect(goneGroup.artworkURL == nil)
        #expect(!goneGroup.isResolved)
        #expect(goneGroup.publishedAt == nil)
    }

    @Test("Most Recent orders episodes by their latest note activity, so an edited old note floats up")
    func recentOrder() {
        let older = note("older", "Older", created: 100)
        let newer = note("newer", "Newer", created: 200)
        let edited = note("edited", "Edited", created: 50, updated: 300)
        let editedSibling = note("edited", "Sibling", created: 60)
        let tieB = note("tie-b", "Tie B", created: 10)
        let tieA = note("tie-a", "Tie A", created: 10)
        let groups = EpisodeNotesLibraryGrouping.groups(
            from: [older, tieB, newer, editedSibling, tieA, edited],
            resolve: { _ in nil },
            matching: "",
            sortedBy: .recent
        )
        #expect(groups.map(\.id) == ["edited", "newer", "older", "tie-a", "tie-b"])
        #expect(groups.first?.latestActivity == Date(timeIntervalSince1970: 300))
    }

    @Test("Show orders by show title with numbers in order, then newest episode, then episode title, untitled episodes last")
    func showOrder() {
        let episodes = [
            "show-10": episode("show-10", show: "Show 10", title: "Ten", publishedAt: 600),
            "show-9": episode("show-9", show: "Show 9", title: "Nine", publishedAt: 700),
            "beta": episode("beta", show: "Beta Show", title: "Beta Episode", publishedAt: 500),
            "alpha-new": episode("alpha-new", show: "Alpha Show", title: "Newest", publishedAt: 300),
            "alpha-9": episode("alpha-9", show: "Alpha Show", title: "Episode 9", publishedAt: 200),
            "alpha-10": episode("alpha-10", show: "Alpha Show", title: "Episode 10", publishedAt: 200),
            "alpha-old": episode("alpha-old", show: "Alpha Show", title: "Oldest", publishedAt: 100),
            "alpha-undated": episode("alpha-undated", show: "Alpha Show", title: "Undated", publishedAt: nil),
        ]
        let notes = [
            note("untitled-b", "Untitled B", created: 9),
            note("beta", "Beta", created: 8),
            note("alpha-old", "Old", created: 7),
            note("untitled-a", "Untitled A", created: 6),
            note("alpha-undated", "Undated", created: 5),
            note("alpha-10", "Ten", created: 4),
            note("alpha-9", "Nine", created: 3),
            note("alpha-new", "New", created: 2),
            note("stored-only", "Stored", created: 1, show: "Gamma Show", title: "Stored Episode"),
            note("show-10", "Show ten", created: 10),
            note("show-9", "Show nine", created: 11),
        ]
        let groups = EpisodeNotesLibraryGrouping.groups(
            from: notes,
            resolve: { episodes[$0] },
            matching: "",
            sortedBy: .show
        )
        #expect(groups.map(\.id) == [
            "alpha-new", "alpha-9", "alpha-10", "alpha-old", "alpha-undated",
            "beta", "stored-only", "show-9", "show-10", "untitled-a", "untitled-b",
        ])
    }

    @Test("Show puts episodes with only an episode title after the titled shows and before episodes with no title")
    func showOrderUntitledTail() {
        let episodes = [
            "episode-dated": episode("episode-dated", show: "", title: "Yak", publishedAt: 100),
            "untitled-c": episode("untitled-c", show: "", title: "", publishedAt: 300),
        ]
        let notes = [
            note("untitled-b", "Untitled B", created: 1),
            note("zebra", "Zebra note", created: 2, title: "Zebra"),
            note("untitled-c", "Untitled C", created: 3),
            note("episode-10", "Ten note", created: 4, title: "Episode 10"),
            note("untitled-a", "Untitled A", created: 5),
            note("episode-9", "Nine note", created: 6, title: "Episode 9"),
            note("episode-dated", "Dated note", created: 7),
            note("titled", "Titled note", created: 8, show: "Alpha Show", title: "Zulu"),
        ]
        let groups = EpisodeNotesLibraryGrouping.groups(
            from: notes,
            resolve: { episodes[$0] },
            matching: "",
            sortedBy: .show
        )
        #expect(groups.map(\.id) == [
            "titled",
            "episode-dated", "episode-9", "episode-10", "zebra",
            "untitled-a", "untitled-b", "untitled-c",
        ])
    }

    @Test("Search matches note text, episode title and show title; a title match keeps the whole episode")
    func searchScopes() {
        let groupsFor = searchFixture()
        let text = groupsFor("sourdough")
        #expect(text.map(\.id) == ["bread"])
        #expect(text.first?.notes.map(\.text) == ["Sourdough starter"])

        // A narrowed episode keeps its place: activity spans all of its notes.
        let narrowed = groupsFor("oven")
        #expect(narrowed.first?.notes.map(\.text) == ["Oven at 250"])
        #expect(narrowed.first?.latestActivity == Date(timeIntervalSince1970: 40))

        let episodeTitle = groupsFor("concurrency")
        #expect(episodeTitle.map(\.id) == ["swift"])
        #expect(episodeTitle.first?.notes.map(\.text) == ["Actors are neat", "Check the link"])

        let showTitle = groupsFor("cooking")
        #expect(showTitle.map(\.id) == ["bread"])
        #expect(showTitle.first?.notes.map(\.text) == ["Sourdough starter", "Oven at 250"])
    }

    @Test("Search trims whitespace and ignores case; a blank query keeps everything; no match is empty")
    func searchQueryHandling() {
        let groupsFor = searchFixture()
        let trimmed = groupsFor("  ACTORS \n")
        #expect(trimmed.map(\.id) == ["swift"])
        #expect(trimmed.first?.notes.map(\.text) == ["Actors are neat"])

        for blank in ["", "   ", "\n"] {
            let all = groupsFor(blank)
            #expect(all.map(\.id) == ["bread", "swift", "gone"])
            #expect(all.map(\.notes.count) == [2, 2, 1])
        }

        #expect(groupsFor("zzqq").isEmpty)
        #expect(groupsFor("unknown").isEmpty)
    }

    @Test("Search ignores accents in note text, episode title and show title", arguments: [false, true])
    func searchIgnoresDiacritics(accentedQuery: Bool) {
        let (query, word) = accentedQuery ? ("Café", "cafe") : ("cafe", "Café")
        let episodes = [
            "episode": episode("episode", show: "Weekly Show", title: "\(word) Culture", publishedAt: 20),
            "show": episode("show", show: "\(word) Talk", title: "Pilot", publishedAt: 10),
        ]
        let notes = [
            note("text", "Meet at the \(word)", created: 3),
            note("text", "Bring a pen", created: 4),
            note("episode", "Espresso", created: 2),
            note("show", "Croissant", created: 1),
            note("other", "Tea", created: 5),
        ]
        let groups = EpisodeNotesLibraryGrouping.groups(
            from: notes,
            resolve: { episodes[$0] },
            matching: query,
            sortedBy: .recent
        )
        #expect(groups.map(\.id) == ["text", "episode", "show"])
        #expect(groups.map { $0.notes.map(\.text) } == [["Meet at the \(word)"], ["Espresso"], ["Croissant"]])
    }

    @Test("Sort order titles and identities")
    func sortOrderTitles() {
        #expect(EpisodeNotesLibrarySortOrder.allCases == [.recent, .show])
        #expect(EpisodeNotesLibrarySortOrder.allCases.map(\.title) == ["Most Recent", "Show"])
        #expect(EpisodeNotesLibrarySortOrder.allCases.map(\.id) == ["recent", "show"])
    }

    private func searchFixture() -> @MainActor (String) -> [EpisodeNotesLibraryGroup] {
        let episodes = [
            "swift": episode("swift", show: "Swift Weekly", title: "Concurrency Deep Dive", publishedAt: 10),
            "bread": episode("bread", show: "Cooking Hour", title: "Bread", publishedAt: 20),
        ]
        let notes = [
            note("swift", "Actors are neat", at: 10, created: 30),
            note("swift", "Check the link", at: 20, created: 31),
            note("bread", "Sourdough starter", at: 5, created: 40),
            note("bread", "Oven at 250", at: 50, created: 20),
            note("gone", "Orphaned thought", created: 1),
        ]
        return { query in
            EpisodeNotesLibraryGrouping.groups(
                from: notes,
                resolve: { episodes[$0] },
                matching: query,
                sortedBy: .recent
            )
        }
    }

    private func note(
        _ episodeID: String,
        _ text: String,
        at timestamp: TimeInterval = 0,
        wholeEpisode: Bool = false,
        created: TimeInterval,
        updated: TimeInterval? = nil,
        show: String = "",
        title: String = "",
        podcastID: String = "",
        artworkURL: String? = nil
    ) -> EpisodeNoteRecord {
        let note = EpisodeNoteRecord(episodeID: episodeID, timestamp: timestamp, text: text)
        note.isEpisodeWide = wholeEpisode
        note.createdAt = Date(timeIntervalSince1970: created)
        note.updatedAt = updated.map(Date.init(timeIntervalSince1970:))
        note.podcastTitle = show
        note.episodeTitle = title
        note.podcastID = podcastID
        note.artworkURL = artworkURL
        return note
    }

    private func episode(_ episodeID: String, show: String, title: String, publishedAt: TimeInterval?) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: episodeID,
            podcastID: "feed:\(show)",
            podcastTitle: show,
            title: title,
            summary: nil,
            publishedAt: publishedAt.map(Date.init(timeIntervalSince1970:)),
            duration: nil,
            audioURL: nil,
            artworkURL: "https://example.com/\(episodeID).jpg",
            artworkPreview: nil,
            guid: nil,
            cachedAt: .now
        )
    }
}
