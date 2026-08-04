import Foundation
import Observation
import OpenCastTranscription

/// Observable state for remote transcription jobs: the active request's
/// phase, the last known dev balance (display only — the server ledger is
/// authoritative), and persisted job references for relaunch recovery.
@Observable
final class RemoteTranscriptionJobStore {
    /// Pending start intent awaiting the consumption preview sheet; set by
    /// the episode menu, consumed by the sheet's Start/Cancel.
    var startPreview: RemoteTranscriptionStartPreviewRequest?

    func dismissStartPreview(ifMatching request: RemoteTranscriptionStartPreviewRequest) {
        guard startPreview == request else {
            return
        }
        startPreview = nil
    }

    private static let referencesDefaultsKey = "remoteTranscription.jobReferences"

    private(set) var activeEpisodeID: String?
    private(set) var activeEpisodeTitle: String?
    private(set) var phase: RemoteTranscriptionRequestPhase?
    private(set) var accountID: String?
    private(set) var balance: OpenCastRemoteTranscriptionBalance?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var activeTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasActiveRequest: Bool {
        activeTask != nil && phase?.isTerminal == false
    }

    func begin(episodeID: String, title: String?) {
        activeEpisodeID = episodeID
        activeEpisodeTitle = title
        phase = .preparing
    }

    func update(phase: RemoteTranscriptionRequestPhase) {
        self.phase = phase
    }

    func finish(phase: RemoteTranscriptionRequestPhase) {
        self.phase = phase
        activeTask = nil
    }

    func updateAccount(_ response: OpenCastRemoteTranscriptionBootstrapResponse) {
        accountID = response.accountID
        balance = response.balance
    }

    func cancelActiveRequest() {
        activeTask?.cancel()
    }

    /// Dismisses a terminal outcome from the failure surface. Live requests
    /// are untouched — cancelling is the only way to end those.
    func dismissTerminalPhase(for episodeID: String) {
        guard activeEpisodeID == episodeID, phase?.isTerminal == true else {
            return
        }
        phase = nil
        activeEpisodeID = nil
        activeEpisodeTitle = nil
    }

    func phase(for episodeID: String) -> RemoteTranscriptionRequestPhase? {
        guard activeEpisodeID == episodeID else {
            return nil
        }
        return phase
    }

    // MARK: Persisted job references

    /// The stable reference for an episode and purpose, minting a new client
    /// request ID only when none is persisted (duplicate submits attach
    /// server-side). Purposes are keyed separately so a detect-ads pass never
    /// attaches to a plain Transcribe Remotely job.
    func reference(
        for episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) -> RemoteTranscriptionJobReference {
        if let existing = references().first(where: {
            $0.episodeID == episodeID && $0.resolvedPurpose == purpose
        }) {
            return existing
        }
        let reference = RemoteTranscriptionJobReference(
            episodeID: episodeID,
            clientRequestID: UUID().uuidString.lowercased(),
            jobID: nil,
            createdAt: .now,
            purpose: purpose
        )
        persist(reference)
        return reference
    }

    func attachJob(
        id jobID: String,
        episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) {
        var reference = reference(for: episodeID, purpose: purpose)
        reference.jobID = jobID
        persist(reference)
    }

    func clearReference(
        for episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) {
        var all = references()
        all.removeAll { $0.episodeID == episodeID && $0.resolvedPurpose == purpose }
        write(all)
    }

    func references() -> [RemoteTranscriptionJobReference] {
        guard let data = defaults.data(forKey: Self.referencesDefaultsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([RemoteTranscriptionJobReference].self, from: data)) ?? []
    }

    private func persist(_ reference: RemoteTranscriptionJobReference) {
        var all = references()
        all.removeAll {
            $0.episodeID == reference.episodeID
                && $0.resolvedPurpose == reference.resolvedPurpose
        }
        all.append(reference)
        write(all)
    }

    private func write(_ references: [RemoteTranscriptionJobReference]) {
        guard let data = try? JSONEncoder().encode(references) else {
            return
        }
        defaults.set(data, forKey: Self.referencesDefaultsKey)
    }
}
