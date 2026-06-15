import Foundation
import Observation

@Observable
final class EpisodeSearchSession {
    private(set) var results: [EpisodeSearchResult] = []
    private(set) var isSearching = false

    @ObservationIgnored private var currentKey: EpisodeSearchRequestKey?
    @ObservationIgnored private var cachedShowNotes: [String: String]?
    @ObservationIgnored private var cachedShowNotesCorpus: EpisodeSearchCorpusKey?

    func update(
        episodes: [EpisodeListItemSnapshot],
        query: String,
        mode: EpisodeSearchMode,
        showNotesProvider: (() async -> [String: String]?)? = nil,
        debounceDuration: Duration = .milliseconds(120)
    ) async {
        let key = EpisodeSearchRequestKey(episodes: episodes, query: query, mode: mode)
        currentKey = key

        guard EpisodeSearch.isSearchActive(query: query) else {
            clearResults()
            return
        }

        do {
            if debounceDuration > .zero {
                try await Task.sleep(for: debounceDuration)
            }
            try Task.checkCancellation()
        } catch {
            return
        }

        guard currentKey == key else {
            return
        }

        results = []
        isSearching = true

        var showNotesHTMLByEpisodeID: [String: String] = [:]
        if let showNotesProvider, EpisodeSearch.usesShowNotes(query: query, mode: mode) {
            if let cachedShowNotes, cachedShowNotesCorpus == key.corpus {
                showNotesHTMLByEpisodeID = cachedShowNotes
            } else {
                let fetchedShowNotes = await showNotesProvider()
                guard !Task.isCancelled, currentKey == key else {
                    return
                }
                // A nil result is a fetch failure: search visible fields this
                // pass, but leave the cache empty so the next keystroke retries.
                if let fetchedShowNotes {
                    showNotesHTMLByEpisodeID = fetchedShowNotes
                    cachedShowNotes = fetchedShowNotes
                    cachedShowNotesCorpus = key.corpus
                }
            }
        }

        let documents = EpisodeSearch.documents(
            from: episodes,
            showNotesHTMLByEpisodeID: showNotesHTMLByEpisodeID
        )
        let matches = await EpisodeSearch.matches(in: documents, query: query, mode: mode)

        guard !Task.isCancelled, currentKey == key else {
            return
        }

        let episodesByID = Dictionary(
            episodes.map { ($0.episodeID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        results = EpisodeSearch.results(
            from: matches,
            episodesByID: episodesByID,
            showNotesHTMLByEpisodeID: showNotesHTMLByEpisodeID
        )
        isSearching = false
    }

    func clear() {
        currentKey = nil
        cachedShowNotes = nil
        cachedShowNotesCorpus = nil
        clearResults()
    }

    private func clearResults() {
        results = []
        isSearching = false
    }
}
