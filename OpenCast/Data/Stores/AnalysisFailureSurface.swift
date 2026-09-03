import Foundation
import Observation

/// The analysis stores' shared failure surface: the last error message,
/// optionally scoped to one episode, plus the change notifier every store
/// transition pulses so drain loops waiting on the store wake up.
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

    /// Clears the failure scoped to `episodeID` (any failure when nil); a
    /// different episode's failure is left standing.
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

    /// Silent reset for callers that republish the whole store afterwards
    /// (load, nuke) and notify once themselves.
    func reset() {
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
    }
}
