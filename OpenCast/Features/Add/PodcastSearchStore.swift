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
            scheduleSearch()
        }
    }

    private(set) var state = PodcastSearchState.idle

    @ObservationIgnored private let directoryService: any PodcastDirectoryService
    @ObservationIgnored private let debounceDuration: Duration
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(
        directoryService: any PodcastDirectoryService = ITunesPodcastDirectoryService(),
        debounceDuration: Duration = .milliseconds(350)
    ) {
        self.directoryService = directoryService
        self.debounceDuration = debounceDuration
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

    private func scheduleSearch() {
        searchTask?.cancel()

        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty else {
            searchTask = nil
            setState(.idle)
            return
        }

        setState(.loading)
        let directoryService = directoryService
        let debounceDuration = debounceDuration

        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounceDuration)
                try Task.checkCancellation()
                let results = try await directoryService.search(query: searchQuery)
                try Task.checkCancellation()
                self?.finishSearch(results: results)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.failSearch(error)
            }
        }
    }

    private func finishSearch(results: [DirectoryPodcastResult]) {
        setState(results.isEmpty ? .empty : .results(results))
        searchTask = nil
    }

    private func failSearch(_ error: Error) {
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
