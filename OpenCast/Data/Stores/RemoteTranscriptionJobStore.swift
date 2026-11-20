import Foundation
import Observation
import OpenCastTranscription

@Observable
final class RemoteTranscriptionJobStore {
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
    /// Display only; the server ledger is authoritative.
    private(set) var balance: OpenCastRemoteTranscriptionBalance?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let diagnostics: any RemoteJobDiagnosticSink
    @ObservationIgnored var activeTask: Task<Void, Never>?
    // `UserDefaults` is not observable; every write bumps this so
    // `references()` registers a dependency.
    private var referencesRevision = 0

    init(
        defaults: UserDefaults = .standard,
        diagnostics: any RemoteJobDiagnosticSink = RemoteJobDiagnosticLog.shared
    ) {
        self.defaults = defaults
        self.diagnostics = diagnostics
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

    /// The client request ID stays stable until the reference is cleared: the server attaches a
    /// duplicate submit to the existing job.
    func reference(
        for episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) -> RemoteTranscriptionJobReference {
        if let existing = existingReference(for: episodeID, purpose: purpose) {
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

    func existingReference(
        for episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) -> RemoteTranscriptionJobReference? {
        references().first { $0.episodeID == episodeID && $0.resolvedPurpose == purpose }
    }

    /// Read before a run starts: a terminal failure clears the reference before its error
    /// reaches the caller.
    func completionDeliveryOwner(
        for episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) -> JobCompletionDeliveryOwner {
        existingReference(for: episodeID, purpose: purpose)?.completionDeliveryOwner ?? .local
    }

    /// Must persist before a create request can leave the process.
    func markCreateAttempted(
        episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) {
        let updated = mutateReference(episodeID: episodeID, purpose: purpose) { reference in
            if reference.createState == .prepared {
                reference.createState = .createAttempted
            }
        }
        record(.createAttempted, reference: updated, disposition: .retained)
    }

    func attachJob(
        id jobID: String,
        episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) {
        _ = reference(for: episodeID, purpose: purpose)
        let updated = mutateReference(episodeID: episodeID, purpose: purpose) { reference in
            reference.jobID = jobID
            reference.createState = .attached
            reference.lastExit = nil
        }
        record(.createAttached, reference: updated, disposition: .attached)
    }

    func recordExit(
        _ exit: RemoteTranscriptionJobExit?,
        episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) {
        let updated = mutateReference(episodeID: episodeID, purpose: purpose) { reference in
            reference.lastExit = exit
        }
        if exit != nil {
            record(.parked, reference: updated, disposition: .parked)
        }
    }

    /// Must persist before any local task is cancelled; while set, automatic re-attach is
    /// suppressed.
    func recordUserCancelIntent(
        episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) {
        let updated = mutateReference(episodeID: episodeID, purpose: purpose) { reference in
            if reference.userCancelRequestedAt == nil {
                reference.userCancelRequestedAt = .now
            }
        }
        record(.userCancelRequested, reference: updated, disposition: .cancelIntentPersisted)
    }

    /// Only a terminal outcome may clear a reference; every recoverable exit keeps it.
    func clearReference(
        for episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) {
        removeReference(for: episodeID, purpose: purpose, kind: .referenceCleared, disposition: .cleared)
    }

    func expireReference(
        for episodeID: String,
        purpose: RemoteTranscriptionJobPurpose
    ) {
        removeReference(for: episodeID, purpose: purpose, kind: .housekeepingExpired, disposition: .expired)
    }

    func references() -> [RemoteTranscriptionJobReference] {
        _ = referencesRevision
        guard let data = defaults.data(forKey: Self.referencesDefaultsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([RemoteTranscriptionJobReference].self, from: data)) ?? []
    }

    @discardableResult
    private func mutateReference(
        episodeID: String,
        purpose: RemoteTranscriptionJobPurpose,
        _ transform: (inout RemoteTranscriptionJobReference) -> Void
    ) -> RemoteTranscriptionJobReference? {
        var all = references()
        guard let index = all.firstIndex(where: {
            $0.episodeID == episodeID && $0.resolvedPurpose == purpose
        }) else {
            return nil
        }
        transform(&all[index])
        write(all)
        return all[index]
    }

    private func removeReference(
        for episodeID: String,
        purpose: RemoteTranscriptionJobPurpose,
        kind: RemoteJobDiagnosticEvent.Kind,
        disposition: RemoteJobDiagnosticEvent.Disposition
    ) {
        var all = references()
        guard let index = all.firstIndex(where: {
            $0.episodeID == episodeID && $0.resolvedPurpose == purpose
        }) else {
            return
        }
        let removed = all.remove(at: index)
        write(all)
        record(kind, reference: removed, disposition: disposition)
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
        referencesRevision &+= 1
    }

    private func record(
        _ kind: RemoteJobDiagnosticEvent.Kind,
        reference: RemoteTranscriptionJobReference?,
        disposition: RemoteJobDiagnosticEvent.Disposition
    ) {
        guard let reference else {
            return
        }
        diagnostics.record(RemoteJobDiagnosticEvent(
            component: .jobStore,
            kind: kind,
            episodeID: reference.episodeID,
            jobID: reference.jobID,
            clientRequestID: reference.clientRequestID,
            purpose: reference.resolvedPurpose,
            disposition: disposition
        ))
    }
}
