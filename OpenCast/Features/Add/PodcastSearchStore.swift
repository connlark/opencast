import Foundation
import Observation
import OpenCastCore

@Observable
final class PodcastSearchStore {
    var query = "" {
        didSet {
            guard query != oldValue else {
                return
            }
            scheduleSearch(after: debounceDuration)
        }
    }

    private(set) var state = PodcastSearchState.idle
    private(set) var answeredQuery: String?

    @ObservationIgnored private let directoryService: any PodcastDirectoryService
    @ObservationIgnored private let knownPodcasts: KnownPodcastsStore
    @ObservationIgnored private let debounceDuration: Duration
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(
        directoryService: any PodcastDirectoryService = ITunesPodcastDirectoryService(),
        knownPodcasts: KnownPodcastsStore,
        debounceDuration: Duration = .milliseconds(350)
    ) {
        self.directoryService = directoryService
        self.knownPodcasts = knownPodcasts
        self.debounceDuration = debounceDuration
    }

    func retrySearch() {
        scheduleSearch(after: .zero)
    }

    func resumeInterruptedSearch() {
        guard searchTask == nil, answeredQuery != trimmedQuery else {
            return
        }
        scheduleSearch(after: .zero)
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        if state == .loading {
            state = .idle
        }
    }

    func waitForCurrentSearch() async {
        await searchTask?.value
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleSearch(after delay: Duration) {
        searchTask?.cancel()

        let searchQuery = trimmedQuery
        guard !searchQuery.isEmpty, !PodcastFeedURLDetector.isAddressLike(searchQuery) else {
            searchTask = nil
            answeredQuery = nil
            setState(.idle)
            return
        }

        switch state {
        case .results:
            break
        case .idle, .loading, .empty, .error:
            answeredQuery = nil
            setState(.loading)
        }
        let directoryService = directoryService

        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                let results = try await directoryService.search(query: searchQuery)
                try Task.checkCancellation()
                self?.finishSearch(results: results, for: searchQuery)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.failSearch(error, for: searchQuery)
            }
        }
    }

    private func finishSearch(results: [DirectoryPodcastResult], for searchQuery: String) {
        for result in results {
            knownPodcasts.learn(result.candidateCanonicalFeedURLStrings, about: result.knownPodcastKey)
        }
        answeredQuery = searchQuery
        setState(results.isEmpty ? .empty : .results(results))
        searchTask = nil
    }

    private func failSearch(_ error: Error, for searchQuery: String) {
        answeredQuery = searchQuery
        setState(.error(error.localizedDescription))
        searchTask = nil
    }

    private func setState(_ newState: PodcastSearchState) {
        guard state != newState else {
            return
        }

        state = newState
    }
}
