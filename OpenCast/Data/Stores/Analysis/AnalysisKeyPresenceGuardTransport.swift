import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization

/// Rereads the Keychain before every send; a key that is absent, replaced or unreadable refuses
/// the send. Provider transports repeat the check through `dispatchCheck` after their pacer admits
/// a send, so a send that waited on the pacer is refused too.
nonisolated struct AnalysisKeyPresenceGuardTransport: AnalysisProviderTransport {
    let inner: any AnalysisProviderTransport
    let provider: AnalysisProvider
    let keyDigest: Data
    let keys: any AnalysisProviderKeyStoring
    let observer: any AnalysisProviderSendObserver
    let onRemoval: @Sendable (AnalysisKeyRequiredReason) -> Void

    /// Final and never retried; status 0 marks that nothing was sent.
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

    /// The caller records the refused send itself.
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

    static func removal(
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

nonisolated final class AnalysisKeyRemovalLog: Sendable {
    private let removals = Mutex<[String: AnalysisKeyRequiredReason]>([:])

    func record(_ reason: AnalysisKeyRequiredReason, runID: String) {
        removals.withLock { $0[runID] = $0[runID] ?? reason }
    }

    func reason(runID: String) -> AnalysisKeyRequiredReason? {
        removals.withLock { $0[runID] }
    }
}
