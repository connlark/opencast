import Foundation
import Observation

@Observable
final class EpisodeSearchSession {
    private(set) var results: [EpisodeSearchResult] = []
    private(set) var isSearching = false
    private(set) var isLoadingVisible = false
    private var resultsKey: EpisodeSearchRequestKey?

    @ObservationIgnored private var currentKey: EpisodeSearchRequestKey?
    @ObservationIgnored private var cachedShowNotes: [String: String]?
    @ObservationIgnored private var cachedShowNotesCorpus: EpisodeSearchCorpusKey?
    @ObservationIgnored private var loadingPresentationTask: Task<Void, Never>?

    func update(
        episodes: [EpisodeListItemSnapshot],
        query: String,
        mode: EpisodeSearchMode,
        showNotesProvider: (() async -> [String: String]?)? = nil,
        loadingPresentationDelay: Duration = .milliseconds(1_500),
        debounceDuration: Duration = .milliseconds(120)
    ) async {
        let key = EpisodeSearchRequestKey(episodes: episodes, query: query, mode: mode)
        let shouldShowLoadingImmediately = shouldShowLoadingImmediately(for: key)
        currentKey = key
        hideLoadingPresentation()

        guard EpisodeSearch.isSearchActive(query: query) else {
            clearResults()
            return
        }

        if shouldShowLoadingImmediately {
            isSearching = true
            scheduleLoadingPresentation(for: key, delay: .zero)
        }

        do {
            if debounceDuration > .zero {
                try await Task.sleep(for: debounceDuration)
            }
            try Task.checkCancellation()
        } catch {
            finishInterruptedSearch(for: key)
            return
        }

        guard currentKey == key else {
            return
        }

        isSearching = true
        if !isLoadingVisible {
            scheduleLoadingPresentation(for: key, delay: loadingPresentationDelay)
        }

        var showNotesHTMLByEpisodeID: [String: String] = [:]
        if let showNotesProvider, EpisodeSearch.usesShowNotes(query: query, mode: mode) {
            if let cachedShowNotes, cachedShowNotesCorpus == key.corpus {
                showNotesHTMLByEpisodeID = cachedShowNotes
            } else {
                let fetchedShowNotes = await showNotesProvider()
                guard !Task.isCancelled, currentKey == key else {
                    finishInterruptedSearch(for: key)
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
            finishInterruptedSearch(for: key)
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
        resultsKey = key
        hideLoadingPresentation()
        isSearching = false
    }

    func displayedResults(for key: EpisodeSearchRequestKey) -> [EpisodeSearchResult] {
        guard let resultsKey,
              resultsKey.corpus == key.corpus,
              // Ignore query so same-scope typing keeps prior compatible results during debounce.
              resultsKey.mode == key.mode
        else {
            return []
        }

        return results
    }

    func clear() {
        currentKey = nil
        cachedShowNotes = nil
        cachedShowNotesCorpus = nil
        clearResults()
    }

    private func clearResults() {
        results = []
        resultsKey = nil
        isSearching = false
        hideLoadingPresentation()
    }

    private func shouldShowLoadingImmediately(for key: EpisodeSearchRequestKey) -> Bool {
        guard EpisodeSearch.isSearchActive(query: key.query),
              let currentKey,
              EpisodeSearch.isSearchActive(query: currentKey.query)
        else {
            return false
        }

        return currentKey.corpus == key.corpus && currentKey.mode != key.mode
    }

    private func scheduleLoadingPresentation(for key: EpisodeSearchRequestKey, delay: Duration) {
        loadingPresentationTask?.cancel()
        loadingPresentationTask = nil

        guard delay > .zero else {
            isLoadingVisible = true
            return
        }

        loadingPresentationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard let self, self.currentKey == key, self.isSearching else {
                return
            }

            self.isLoadingVisible = true
        }
    }

    private func hideLoadingPresentation() {
        loadingPresentationTask?.cancel()
        loadingPresentationTask = nil
        isLoadingVisible = false
    }

    private func finishInterruptedSearch(for key: EpisodeSearchRequestKey) {
        guard currentKey == key else {
            return
        }

        isSearching = false
        hideLoadingPresentation()
    }
}
