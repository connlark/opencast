import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization

/// Stops a direct run once the listener's key for its provider is gone:
/// before every send it reads the Keychain again (an iCloud Keychain removal
/// counts), and a key that is absent, replaced or unreadable refuses the
/// send without reaching the provider. The provider transport runs the same
/// check (``dispatchCheck(provider:keyDigest:keys:onRemoval:)``) after its
/// pacer admits the send and right before it leaves, so a send that waited
/// for the pacer is refused too. The refusal is final, so the pipeline
/// cancels the run's other windows; sends already out may finish.
nonisolated struct AnalysisKeyPresenceGuardTransport: AnalysisProviderTransport {
    let inner: any AnalysisProviderTransport
    let provider: AnalysisProvider
    /// The digest of the key the run was resolved with.
    let keyDigest: Data
    let keys: any AnalysisProviderKeyStoring
    let observer: any AnalysisProviderSendObserver
    /// Told why the run lost its key, at the first refused send.
    let onRemoval: @Sendable (AnalysisKeyRequiredReason) -> Void

    /// How a refused send fails: final, never retried, nothing sent.
    static let refusal = AnalysisProviderErrorClassification(transport: .rejected(status: 0), listener: .keyRequired)

    func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        if let removal = Self.removal(provider: provider, keyDigest: keyDigest, keys: keys) {
            onRemoval(removal)
            observer.record(AnalysisProviderSendRecord(
                provider: provider,
                modelID: request.model.modelID,
                feature: request.feature,
                purpose: request.purpose,
                sendIndex: request.sendIndex,
                status: nil,
                finishReason: nil,
                failure: Self.refusal.listener,
                usage: nil,
                pacedSeconds: 0,
                exchangeSeconds: 0
            ))
            throw Self.refusal.transport
        }
        return try await inner.send(request)
    }

    /// The check a provider transport runs after its pacer admits a send;
    /// the transport records the refused send itself.
    static func dispatchCheck(
        provider: AnalysisProvider,
        keyDigest: Data,
        keys: any AnalysisProviderKeyStoring,
        onRemoval: @escaping @Sendable (AnalysisKeyRequiredReason) -> Void
    ) -> AnalysisPreDispatchCheck {
        {
            guard let removal = removal(provider: provider, keyDigest: keyDigest, keys: keys) else {
                return nil
            }
            onRemoval(removal)
            return refusal
        }
    }

    /// Why the run's key no longer stands, read from the Keychain now.
    private static func removal(
        provider: AnalysisProvider,
        keyDigest: Data,
        keys: any AnalysisProviderKeyStoring
    ) -> AnalysisKeyRequiredReason? {
        let key: AnalysisProviderKey?
        do {
            key = try keys.key(for: provider)
        } catch {
            return .keychainUnreadable
        }
        return key?.digest == keyDigest ? nil : .noKey
    }
}

/// Why each run lost its key, by run id.
nonisolated final class AnalysisKeyRemovalLog: Sendable {
    private let removals = Mutex<[String: AnalysisKeyRequiredReason]>([:])

    /// Keeps the first reason a run reported.
    func record(_ reason: AnalysisKeyRequiredReason, runID: String) {
        removals.withLock { $0[runID] = $0[runID] ?? reason }
    }

    func reason(runID: String) -> AnalysisKeyRequiredReason? {
        removals.withLock { $0[runID] }
    }
}
