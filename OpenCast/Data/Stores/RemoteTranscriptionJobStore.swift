import Foundation
import Observation
import OpenCastTranscription

/// Observable state for remote transcription jobs: the active request's
/// phase, the last known dev balance (display only — the server ledger is
/// authoritative), and persisted job references for relaunch recovery.
///
/// Every persisted-reference change goes through one main-actor mutation
/// path (`mutateReference`), so a create attempt, an attach, an exit, a
/// user-cancel intent and a clear can never interleave, and each one leaves
/// a typed diagnostic event behind.
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
    @ObservationIgnored let diagnostics: any RemoteJobDiagnosticSink
    @ObservationIgnored var activeTask: Task<Void, Never>?

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

    /// Dismisses a terminal outcome from the failure surface. Live and parked
    /// requests are untouched — Resume or a user cancel ends those.
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

    /// The persisted reference, if any, without minting one.
    func existingReference(
        for episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) -> RemoteTranscriptionJobReference? {
        references().first { $0.episodeID == episodeID && $0.resolvedPurpose == purpose }
    }

    /// Persisted immediately before a create request can leave the process.
    /// The create state only moves forward, so an attached reference is left
    /// alone.
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

    /// Records the last recoverable exit on an existing reference. A missing
    /// reference is left alone: an exit never mints one.
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

    /// Persists the user's cancel intent before any local task is cancelled.
    /// While it is set, automatic re-attach is suppressed; only the
    /// user-authorized cancel path resolves and clears the reference.
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

    /// Terminal cleanup. Only a terminal server state, a durable import and
    /// ack, a resolved user cancel, a conclusive first-attempt rejection or
    /// the unfunded detect reservation bail may clear a reference; every
    /// recoverable exit keeps it.
    func clearReference(
        for episodeID: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription
    ) {
        var all = references()
        guard let index = all.firstIndex(where: {
            $0.episodeID == episodeID && $0.resolvedPurpose == purpose
        }) else {
            return
        }
        let removed = all.remove(at: index)
        write(all)
        record(.referenceCleared, reference: removed, disposition: .cleared)
    }

    func references() -> [RemoteTranscriptionJobReference] {
        guard let data = defaults.data(forKey: Self.referencesDefaultsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([RemoteTranscriptionJobReference].self, from: data)) ?? []
    }

    /// The single read-modify-write path for an existing reference. Returns
    /// the persisted result, or nil when no reference exists (nothing is
    /// minted here).
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
