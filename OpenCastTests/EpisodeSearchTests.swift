import Foundation
import SwiftUI
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode search")
struct EpisodeSearchTests {
    @Test("Blank query returns the unfiltered source list")
    func blankQueryReturnsUnfilteredSourceList() {
        let episodes = [
            makeEpisode(id: "new", title: "Newest Episode", publishedAt: 200),
            makeEpisode(id: "old", title: "Oldest Episode", publishedAt: 100)
        ]

        let results = EpisodeSearch.results(in: episodes, query: "   ", mode: .fullText)

        #expect(resultIDs(results) == ["new", "old"])
        #expect(results.allSatisfy { $0.snippet == nil })
    }

    @Test("Search session skips blank queries")
    func searchSessionSkipsBlankQueries() async {
        let episodes = (0..<250).map { index in
            makeEpisode(
                id: "episode-\(index)",
                title: "Episode \(index)",
                summary: "Summary text \(index)",
                publishedAt: TimeInterval(index)
            )
        }
        let showNotesByID = Dictionary(
            uniqueKeysWithValues: (0..<250).map { index in
                ("episode-\(index)", "<p>Show notes text \(index)</p>")
            }
        )
        let session = EpisodeSearchSession()

        await session.update(
            episodes: episodes,
            query: "   ",
            mode: .fullText,
            showNotesProvider: { showNotesByID },
            debounceDuration: .zero
        )

        #expect(session.results.isEmpty)
        #expect(session.isSearching == false)
    }

    @Test("Search session returns nonblank query results")
    func searchSessionReturnsNonblankQueryResults() async throws {
        let episodes = [
            makeEpisode(id: "miss", title: "Daily Notes"),
            makeEpisode(id: "match", title: "Workbench", summary: "Keyboard membrane repair tips.")
        ]
        let session = EpisodeSearchSession()

        await session.update(
            episodes: episodes,
            query: "keyboard",
            mode: .fullText,
            debounceDuration: .zero
        )

        let result = try #require(session.results.first)
        #expect(result.episode.episodeID == "match")
        #expect(plainText(result.snippet).contains("Keyboard membrane"))
        #expect(session.isSearching == false)
    }

    @Test("Search session keeps prior results during debounce")
    func searchSessionKeepsPriorResultsDuringDebounce() async throws {
        let episodes = [
            makeEpisode(id: "keyboard", title: "Workbench", summary: "Keyboard membrane repair tips."),
            makeEpisode(id: "soldering", title: "Radio Lab", summary: "Soldering station checklist.")
        ]
        let session = EpisodeSearchSession()

        await session.update(
            episodes: episodes,
            query: "keyboard",
            mode: .fullText,
            debounceDuration: .zero
        )
        #expect(resultIDs(session.results) == ["keyboard"])
        #expect(session.isSearching == false)

        let searchTask = Task {
            await session.update(
                episodes: episodes,
                query: "soldering",
                mode: .fullText,
                debounceDuration: .seconds(1)
            )
        }
        defer {
            searchTask.cancel()
        }
        let pendingKey = EpisodeSearchRequestKey(
            episodes: episodes,
            query: "soldering",
            mode: .fullText
        )

        try await Task.sleep(for: .milliseconds(80))

        #expect(resultIDs(session.results) == ["keyboard"])
        #expect(resultIDs(session.displayedResults(for: pendingKey)) == ["keyboard"])
        #expect(session.isSearching == false)

        await searchTask.value

        #expect(resultIDs(session.results) == ["soldering"])
        #expect(resultIDs(session.displayedResults(for: pendingKey)) == ["soldering"])
        #expect(session.isSearching == false)
    }

    @Test("Search session hides prior scope results while switched scope is pending")
    func searchSessionHidesPriorScopeResultsWhileSwitchedScopeIsPending() async throws {
        let episodes = [
            makeEpisode(id: "title", title: "Robot Repairs"),
            makeEpisode(id: "notes", title: "Archive")
        ]
        let session = EpisodeSearchSession()

        await session.update(
            episodes: episodes,
            query: "robot",
            mode: .episodes,
            debounceDuration: .zero
        )

        let episodesKey = EpisodeSearchRequestKey(
            episodes: episodes,
            query: "robot",
            mode: .episodes
        )
        let fullTextKey = EpisodeSearchRequestKey(
            episodes: episodes,
            query: "robot",
            mode: .fullText
        )

        #expect(resultIDs(session.displayedResults(for: episodesKey)) == ["title"])

        let showNotesProvider = PendingShowNotesProvider()
        let searchTask = Task {
            await session.update(
                episodes: episodes,
                query: "robot",
                mode: .fullText,
                showNotesProvider: { await showNotesProvider.value() },
                loadingPresentationDelay: .seconds(5),
                debounceDuration: .zero
            )
        }
        defer {
            searchTask.cancel()
        }

        await showNotesProvider.waitUntilStarted()

        #expect(resultIDs(session.results) == ["title"])
        #expect(session.displayedResults(for: fullTextKey).isEmpty)

        await showNotesProvider.finish(returning: ["notes": "<p>Robot appendix.</p>"])
        await searchTask.value

        #expect(resultIDs(session.displayedResults(for: fullTextKey)) == ["title", "notes"])
        #expect(session.isSearching == false)
        #expect(session.isLoadingVisible == false)
    }

    @Test("Search session shows loading immediately when scope changes")
    func searchSessionShowsLoadingImmediatelyWhenScopeChanges() async throws {
        let episodes = [
            makeEpisode(id: "match", title: "Robot Repairs")
        ]
        let session = EpisodeSearchSession()

        await session.update(
            episodes: episodes,
            query: "robot",
            mode: .episodes,
            debounceDuration: .zero
        )

        let showNotesProvider = PendingShowNotesProvider()
        let searchTask = Task {
            await session.update(
                episodes: episodes,
                query: "robot",
                mode: .fullText,
                showNotesProvider: { await showNotesProvider.value() },
                loadingPresentationDelay: .seconds(30),
                debounceDuration: .milliseconds(120)
            )
        }
        defer {
            searchTask.cancel()
        }

        try await waitUntil("scope switch loading presentation") {
            session.isSearching && session.isLoadingVisible
        }

        #expect(session.isSearching == true)
        #expect(session.isLoadingVisible == true)

        await showNotesProvider.waitUntilStarted()
        await showNotesProvider.finish(returning: [:])
        await searchTask.value

        #expect(session.isSearching == false)
        #expect(session.isLoadingVisible == false)
    }

    @Test("Search session suppresses loading presentation for fast searches")
    func searchSessionSuppressesLoadingPresentationForFastSearches() async {
        let episodes = [
            makeEpisode(id: "match", title: "Workbench", summary: "Keyboard membrane repair tips.")
        ]
        let session = EpisodeSearchSession()

        await session.update(
            episodes: episodes,
            query: "keyboard",
            mode: .fullText,
            loadingPresentationDelay: .seconds(1),
            debounceDuration: .zero
        )

        #expect(resultIDs(session.results) == ["match"])
        #expect(session.isSearching == false)
        #expect(session.isLoadingVisible == false)
    }

    @Test("Search session delays loading presentation for slow searches")
    func searchSessionDelaysLoadingPresentationForSlowSearches() async throws {
        let episodes = [
            makeEpisode(id: "match", title: "Workbench", summary: "Keyboard membrane repair tips.")
        ]
        let session = EpisodeSearchSession()

        let showNotesProvider = PendingShowNotesProvider()
        let searchTask = Task {
            await session.update(
                episodes: episodes,
                query: "keyboard",
                mode: .fullText,
                showNotesProvider: { await showNotesProvider.value() },
                loadingPresentationDelay: .seconds(2),
                debounceDuration: .zero
            )
        }

        await showNotesProvider.waitUntilStarted()
        #expect(session.isSearching == true)
        #expect(session.isLoadingVisible == false)

        try await waitUntil("delayed loading presentation", timeout: .seconds(3)) {
            session.isLoadingVisible
        }
        #expect(session.isSearching == true)
        #expect(session.isLoadingVisible == true)

        await showNotesProvider.finish(returning: [:])
        await searchTask.value

        #expect(resultIDs(session.results) == ["match"])
        #expect(session.isSearching == false)
        #expect(session.isLoadingVisible == false)
    }

    @Test("Episodes mode matches visible fields with all query tokens")
    func episodesModeMatchesVisibleFieldsWithAllQueryTokens() {
        let episodes = [
            makeEpisode(id: "title", podcastTitle: "Future Talk", title: "Robot Ethics"),
            makeEpisode(id: "podcast", podcastTitle: "Robot Radio", title: "Weekly Digest"),
            makeEpisode(id: "cross-field", podcastTitle: "Future Talk", title: "Launch Window"),
            makeEpisode(id: "miss", podcastTitle: "History Hour", title: "Launch Window")
        ]

        #expect(resultIDs(EpisodeSearch.results(in: episodes, query: "robot", mode: .episodes)) == ["title", "podcast"])
        #expect(resultIDs(EpisodeSearch.results(in: episodes, query: "launch future", mode: .episodes)) == ["cross-field"])
    }

    @Test("Episodes mode is case and diacritic insensitive")
    func episodesModeIsCaseAndDiacriticInsensitive() {
        let episodes = [
            makeEpisode(id: "accented", title: "Café Culture"),
            makeEpisode(id: "plain", title: "Tea Culture")
        ]

        let results = EpisodeSearch.results(in: episodes, query: "CAFE", mode: .episodes)

        #expect(resultIDs(results) == ["accented"])
    }

    @Test("Episodes mode preserves source order")
    func episodesModePreservesSourceOrder() {
        let episodes = [
            makeEpisode(id: "newest", title: "Robot Repairs", publishedAt: 300),
            makeEpisode(id: "middle", title: "Robot Roundtable", publishedAt: 200),
            makeEpisode(id: "oldest", title: "Robot Archive", publishedAt: 100)
        ]

        let results = EpisodeSearch.results(in: episodes, query: "robot", mode: .episodes)

        #expect(resultIDs(results) == ["newest", "middle", "oldest"])
    }

    @Test("Full text searches summary and show notes as plain text")
    func fullTextSearchesSummaryAndShowNotesAsPlainText() {
        let episodes = [
            makeEpisode(id: "summary", title: "Daily Notes", summary: "<p>Keyboard membrane repair tips.</p>"),
            makeEpisode(id: "notes", title: "Workbench")
        ]
        let showNotesByID = ["notes": "<ul><li>Soldering station checklist</li></ul>"]

        let summaryResults = EpisodeSearch.results(
            in: episodes,
            query: "keyboard",
            mode: .fullText,
            showNotesHTMLByEpisodeID: showNotesByID
        )
        let showNotesResults = EpisodeSearch.results(
            in: episodes,
            query: "soldering",
            mode: .fullText,
            showNotesHTMLByEpisodeID: showNotesByID
        )

        #expect(resultIDs(summaryResults) == ["summary"])
        #expect(resultIDs(showNotesResults) == ["notes"])
        #expect(plainText(showNotesResults[0].snippet).contains("<li>") == false)
    }

    @Test("Full text ranks visible matches before summary and show notes")
    func fullTextRanksVisibleMatchesBeforeSummaryAndShowNotes() {
        let episodes = [
            makeEpisode(id: "notes-new", title: "Newest", publishedAt: 400),
            makeEpisode(id: "summary-new", title: "Middle", summary: "Nebula summary.", publishedAt: 300),
            makeEpisode(id: "summary-old", title: "Older", summary: "Nebula analysis.", publishedAt: 200),
            makeEpisode(id: "title-old", title: "Nebula Dispatch", publishedAt: 100)
        ]
        let showNotesByID = ["notes-new": "<p>Nebula appendix.</p>"]

        let results = EpisodeSearch.results(
            in: episodes,
            query: "nebula",
            mode: .fullText,
            showNotesHTMLByEpisodeID: showNotesByID
        )

        #expect(resultIDs(results) == ["title-old", "summary-new", "summary-old", "notes-new"])
    }

    @Test("Full text below three characters falls back to visible exact matching")
    func fullTextBelowThreeCharactersFallsBackToVisibleExactMatching() {
        let episodes = [
            makeEpisode(id: "summary", title: "Machine Notes", summary: "AI appears only in this summary."),
            makeEpisode(id: "title", title: "AI Guide")
        ]

        let results = EpisodeSearch.results(in: episodes, query: "ai", mode: .fullText)

        #expect(resultIDs(results) == ["title"])
    }

    @Test("Fuzzy full text catches agreed typo thresholds")
    func fuzzyFullTextCatchesAgreedTypoThresholds() {
        let episodes = [
            makeEpisode(id: "short", title: "Robot Repairs"),
            makeEpisode(id: "long", title: "Archive", summary: "A careful history of portable radio.")
        ]

        let shortResults = EpisodeSearch.results(in: episodes, query: "robt", mode: .fullText)
        let longResults = EpisodeSearch.results(in: episodes, query: "histroy", mode: .fullText)

        #expect(resultIDs(shortResults) == ["short"])
        #expect(resultIDs(longResults) == ["long"])
    }

    @Test("Fuzzy matching highlights the actual matched word")
    func fuzzyMatchingHighlightsActualMatchedWord() throws {
        let episodes = [
            makeEpisode(id: "robot", title: "Robot Repairs")
        ]

        let result = try #require(EpisodeSearch.results(in: episodes, query: "robt", mode: .fullText).first)

        #expect(highlightedSegments(in: result.highlightedTitle) == ["Robot"])
    }

    @Test("Hidden full text matches create summary-first snippets")
    func hiddenFullTextMatchesCreateSummaryFirstSnippets() throws {
        let summary = """
        Before the term appears, the discussion walks through cache warmup, playback handoff, and transcript cleanup. \
        The summary vector passage explains why local matching is useful while staying offline. \
        Afterward the hosts compare several queue designs for the inbox.
        """
        let showNotes = "<p>The show notes vector passage should not be preferred.</p>"
        let episodes = [
            makeEpisode(id: "snippet", title: "Search Notes", summary: summary)
        ]

        let result = try #require(
            EpisodeSearch.results(
                in: episodes,
                query: "vector",
                mode: .fullText,
                showNotesHTMLByEpisodeID: ["snippet": showNotes]
            ).first
        )
        let snippetText = plainText(result.snippet)

        #expect(snippetText.contains("summary vector passage"))
        #expect(snippetText.contains("show notes vector") == false)
        #expect(snippetText.count <= 180)
        #expect(highlightedSegments(in: try #require(result.snippet)) == ["vector"])
    }

    @Test("Visible matches are highlighted in title and podcast title")
    func visibleMatchesAreHighlightedInTitleAndPodcastTitle() throws {
        let episodes = [
            makeEpisode(id: "visible", podcastTitle: "Future Talk", title: "Robot Ethics")
        ]

        let result = try #require(EpisodeSearch.results(in: episodes, query: "robot future", mode: .episodes).first)

        #expect(highlightedSegments(in: result.highlightedTitle) == ["Robot"])
        #expect(highlightedSegments(in: result.highlightedPodcastTitle) == ["Future"])
    }

    private func makeEpisode(
        id: String,
        podcastTitle: String = "Example Podcast",
        title: String,
        summary: String? = nil,
        publishedAt: TimeInterval = 100
    ) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: id,
            podcastID: "https://example.com/feed.xml",
            podcastTitle: podcastTitle,
            title: title,
            summary: summary,
            publishedAt: Date(timeIntervalSince1970: publishedAt),
            duration: nil,
            audioURL: nil,
            artworkURL: nil,
            artworkPreview: nil,
            guid: nil,
            cachedAt: .now
        )
    }

    private func resultIDs(_ results: [EpisodeSearchResult]) -> [String] {
        results.map(\.episode.episodeID)
    }

    private func plainText(_ attributed: AttributedString?) -> String {
        guard let attributed else {
            return ""
        }

        return String(attributed.characters)
    }

    private func highlightedSegments(in attributed: AttributedString) -> [String] {
        attributed.runs.compactMap { run in
            guard run.inlinePresentationIntent == .stronglyEmphasized,
                  run.foregroundColor != nil
            else {
                return nil
            }

            return String(attributed[run.range].characters)
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(20),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: pollInterval)
        }

        throw WaitTimeoutError(description: description)
    }

    private struct WaitTimeoutError: Error, CustomStringConvertible {
        let description: String
    }

    private actor PendingShowNotesProvider {
        private var hasStarted = false
        private var startContinuation: CheckedContinuation<Void, Never>?
        private var resultContinuation: CheckedContinuation<[String: String]?, Never>?

        func value() async -> [String: String]? {
            await withCheckedContinuation { continuation in
                resultContinuation = continuation
                hasStarted = true
                startContinuation?.resume()
                startContinuation = nil
            }
        }

        func waitUntilStarted() async {
            if hasStarted {
                return
            }

            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }

        func finish(returning result: [String: String]?) {
            resultContinuation?.resume(returning: result)
            resultContinuation = nil
        }
    }
}
