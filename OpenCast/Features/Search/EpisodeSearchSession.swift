import Foundation
import Observation

@Observable
final class EpisodeSearchSession {
    private(set) var results: [EpisodeSearchResult] = []
    private(set) var isSearching = false
    private(set) var isLoadingVisible = false
    /// True while results come from the bounded fallback because the derived
    /// index could not answer (not ready, rebuilding, or store failure).
    /// Surfaces let the user know results are temporarily title-only.
    private(set) var isIndexedSearchUnavailable = false
    private var resultsKey: EpisodeSearchRequestKey?

    @ObservationIgnored private var currentKey: EpisodeSearchRequestKey?
    @ObservationIgnored private var cachedShowNotes: [String: String]?
    @ObservationIgnored private var cachedShowNotesCorpus: EpisodeSearchCorpusKey?
    @ObservationIgnored private var cachedEpisodesByID:
        [String: EpisodeListItemSnapshot]?
    @ObservationIgnored private var cachedEpisodeCorpus: EpisodeSearchCorpusKey?
    @ObservationIgnored private var loadingPresentationTask: Task<Void, Never>?

    /// `unindexedEpisodes` are episodes in `episodes` that the derived index
    /// cannot serve (orphaned downloads whose podcast was unsubscribed and
    /// whose cache rows are gone). When the indexed path answers, these are
    /// matched with the legacy matcher and appended so they stay findable.
    func update(
        episodes: [EpisodeListItemSnapshot],
        query: String,
        mode: EpisodeSearchMode,
        corpusRevision: Int? = nil,
        unindexedEpisodes: [EpisodeListItemSnapshot] = [],
        indexedSearchProvider: (() async -> [EpisodeSearchIndexHit]?)? = nil,
        showNotesProvider: (() async -> [String: String]?)? = nil,
        loadingPresentationDelay: Duration = .milliseconds(1_500),
        debounceDuration: Duration = .milliseconds(120)
    ) async {
        let key = EpisodeSearchRequestKey(
            episodes: episodes,
            query: query,
            mode: mode,
            corpusRevision: corpusRevision
        )
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

        if let indexedSearchProvider,
           let indexedHits = await indexedSearchProvider() {
            guard !Task.isCancelled, currentKey == key else {
                finishInterruptedSearch(for: key)
                return
            }
            let episodesByID = episodeLookup(
                episodes: episodes,
                corpus: key.corpus
            )
            var indexedResults = EpisodeSearch.results(
                from: indexedHits,
                episodesByID: episodesByID
            )
            if !unindexedEpisodes.isEmpty {
                let matches = await EpisodeSearch.matches(
                    in: unindexedEpisodes,
                    query: query,
                    mode: mode
                )
                guard !Task.isCancelled, currentKey == key else {
                    finishInterruptedSearch(for: key)
                    return
                }
                let indexedEpisodeIDs = Set(
                    indexedResults.map(\.episode.episodeID)
                )
                indexedResults += EpisodeSearch.results(
                    from: matches,
                    episodesByID: episodesByID
                ).filter { !indexedEpisodeIDs.contains($0.episode.episodeID) }
            }
            results = indexedResults
            resultsKey = key
            isIndexedSearchUnavailable = false
            hideLoadingPresentation()
            isSearching = false
            return
        }

        // An indexed provider reports cancellation as no result so the
        // derived-index failure path can share the legacy fallback. Do not let
        // a cancelled superseded request turn that nil into an expensive
        // fallback scan.
        guard !Task.isCancelled, currentKey == key else {
            finishInterruptedSearch(for: key)
            return
        }

        // A present provider answering nil means the derived index cannot
        // serve right now. The plan's index-not-ready contract is a *bounded*
        // fallback: match visible fields only and skip the show-notes corpus
        // fetch — the full six-bucket scan is exactly the per-keystroke cost
        // the index exists to eliminate. Callers with no indexed provider at
        // all keep the complete legacy semantics.
        let isBoundedFallback = indexedSearchProvider != nil
        isIndexedSearchUnavailable = isBoundedFallback

        var showNotesHTMLByEpisodeID: [String: String] = [:]
        if !isBoundedFallback,
           let showNotesProvider,
           EpisodeSearch.usesShowNotes(query: query, mode: mode) {
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

        let matches = await EpisodeSearch.matches(
            in: episodes,
            showNotesHTMLByEpisodeID: showNotesHTMLByEpisodeID,
            query: query,
            mode: isBoundedFallback ? .episodes : mode
        )

        guard !Task.isCancelled, currentKey == key else {
            finishInterruptedSearch(for: key)
            return
        }

        let episodesByID = episodeLookup(
            episodes: episodes,
            corpus: key.corpus
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
        cachedEpisodesByID = nil
        cachedEpisodeCorpus = nil
        clearResults()
    }

    private func episodeLookup(
        episodes: [EpisodeListItemSnapshot],
        corpus: EpisodeSearchCorpusKey
    ) -> [String: EpisodeListItemSnapshot] {
        // Without a caller-supplied revision the corpus key is a shape probe
        // (count + boundary IDs + newest cachedAt) that a middle-of-list
        // membership change can collide with, and a stale lookup silently
        // drops index hits. Cache only when the key carries a real revision.
        if corpus.sourceRevision != nil,
           let cachedEpisodesByID,
           cachedEpisodeCorpus == corpus {
            return cachedEpisodesByID
        }
        let episodesByID = Dictionary(
            episodes.map { ($0.episodeID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        cachedEpisodesByID = episodesByID
        cachedEpisodeCorpus = corpus
        return episodesByID
    }

    private func clearResults() {
        results = []
        resultsKey = nil
        isSearching = false
        isIndexedSearchUnavailable = false
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
