import Foundation
import Observation

@Observable
final class AnalysisFailureSurface {
    private(set) var lastErrorMessage: String?
    private(set) var lastErrorEpisodeID: String?
    @ObservationIgnored let stateChanges = StoreChangeNotifier()

    var changeSequence: Int {
        stateChanges.sequence
    }

    func waitForChange(after sequence: Int) async throws {
        try await stateChanges.wait(after: sequence)
    }

    func message(for episodeID: String) -> String? {
        guard lastErrorEpisodeID == episodeID else {
            return nil
        }
        return lastErrorMessage
    }

    func record(_ error: any Error, episodeID: String? = nil) {
        record(message: error.localizedDescription, episodeID: episodeID)
    }

    func record(message: String, episodeID: String? = nil) {
        lastErrorMessage = message
        lastErrorEpisodeID = episodeID
        stateChanges.notify()
    }

    /// Leaves a different episode's failure standing.
    func clear(episodeID: String? = nil) {
        guard episodeID == nil || lastErrorEpisodeID == nil || lastErrorEpisodeID == episodeID else {
            return
        }
        let hadFailure = lastErrorMessage != nil || lastErrorEpisodeID != nil
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
        if hadFailure {
            stateChanges.notify()
        }
    }

    /// Does not notify: the caller republishes the whole store and notifies once.
    func reset() {
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
    }
}
