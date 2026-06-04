import Foundation
import Observation

@Observable
final class EpisodeSearchSession {
    private(set) var results: [EpisodeSearchResult] = []
    private(set) var isSearching = false

    @ObservationIgnored private var currentKey: EpisodeSearchRequestKey?

    func update(
        episodes: [EpisodeCacheRecord],
        query: String,
        mode: EpisodeSearchMode,
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

        let documents = EpisodeSearch.documents(from: episodes)
        let matches = await EpisodeSearch.matches(in: documents, query: query, mode: mode)

        guard !Task.isCancelled, currentKey == key else {
            return
        }

        let episodesByID = Dictionary(
            episodes.map { ($0.episodeID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        results = EpisodeSearch.results(from: matches, episodesByID: episodesByID)
        isSearching = false
    }

    func clear() {
        currentKey = nil
        clearResults()
    }

    private func clearResults() {
        results = []
        isSearching = false
    }
}
