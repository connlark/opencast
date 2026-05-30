import Foundation
import Observation
import OpenCastCore

@Observable
final class PopularPodcastsStore {
    private(set) var state = PopularPodcastsState.idle

    @ObservationIgnored private let discoveryService: any PodcastDiscoveryService

    init(discoveryService: any PodcastDiscoveryService) {
        self.discoveryService = discoveryService
    }

    func loadPopularIfNeeded() async {
        guard state == .idle else {
            return
        }

        state = .loading
        do {
            let results = try await discoveryService.popular(
                limit: 8,
                country: Locale.current.region?.identifier ?? "us",
                allowExplicit: true
            )
            try Task.checkCancellation()
            finishLoad(results: results)
        } catch is CancellationError {
            if state == .loading {
                state = .idle
            }
        } catch {
            failLoad(error)
        }
    }

    private func finishLoad(results: [DirectoryPodcastResult]) {
        state = results.isEmpty ? .empty : .loaded(results)
    }

    private func failLoad(_ error: Error) {
        state = .failed(error.localizedDescription)
    }
}
