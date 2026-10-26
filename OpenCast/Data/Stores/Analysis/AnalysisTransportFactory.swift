import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

/// Why a run's transport could not be built.
nonisolated enum AnalysisTransportFactoryError: Error, Sendable, Hashable {
    /// The resolution has no route to send on.
    case keyRequired(AnalysisKeyRequiredReason)
    /// The bundle has no usable endpoint for the provider.
    case configuration(AnalysisProviderConfigurationError)
}

/// Builds one run's transport from its resolved route: the listener's key
/// with the provider's endpoint from the active bundle and the key's
/// session pacer, or the trial service's exchange. The transport holds the
/// key for this run only, and reads the Keychain before each send and again
/// once the key's pacer admits it, so a removed or replaced key stops the run
/// even for a send that waited. Every transport answers a resumed
/// run's earlier replies from the run's sidecar (without the key) and keeps
/// new ones.
final class AnalysisTransportFactory {
    private let policy: AnalysisPolicySnapshotStore
    private let runs: AnalysisRunRecordStore
    /// The listener's keys as stored, read before every direct send.
    private let keys: any AnalysisProviderKeyStoring
    private let removals = AnalysisKeyRemovalLog()
    /// UI tests: answers every run without the network.
    private let fixture: AnalysisUITestTransportMode?
    private let client: any AnalysisHTTPClient

    init(
        policy: AnalysisPolicySnapshotStore,
        runs: AnalysisRunRecordStore,
        keys: any AnalysisProviderKeyStoring,
        fixture: AnalysisUITestTransportMode? = nil,
        client: any AnalysisHTTPClient = URLSessionAnalysisHTTPClient()
    ) {
        self.policy = policy
        self.runs = runs
        self.keys = keys
        self.fixture = fixture
        self.client = client
    }

    func makeTransport(
        for resolution: AnalysisRouteResolution,
        runID: String,
        observer: any AnalysisProviderSendObserver,
        onReused: @escaping @Sendable (AnalysisProviderRequest) -> Void = { _ in }
    ) throws(AnalysisTransportFactoryError) -> any AnalysisProviderTransport {
        let inner = try innerTransport(for: resolution, runID: runID, observer: observer)
        return AnalysisResumingTransport(inner: inner, store: runs, runID: runID, onReused: onReused)
    }

    /// Why the run lost its listener's key, when a send found it gone.
    func keyRemoval(runID: String) -> AnalysisKeyRequiredReason? {
        removals.reason(runID: runID)
    }

    private func innerTransport(
        for resolution: AnalysisRouteResolution,
        runID: String,
        observer: any AnalysisProviderSendObserver
    ) throws(AnalysisTransportFactoryError) -> any AnalysisProviderTransport {
        if let reason = resolution.keyRequiredReason { throw .keyRequired(reason) }
        if let fixture {
            return AnalysisUITestFixtureTransport(mode: fixture, route: resolution.route, observer: observer)
        }
        let logger = RedactingLogger(category: "AnalysisRun")
        switch resolution.route {
        case .keyRequired(let reason):
            throw .keyRequired(reason)
        case .trial:
            guard let exchange = resolution.trialExchange else { throw .keyRequired(.proxyUnavailable) }
            return TrialProxyAnalysisTransport(runID: runID, exchange: exchange, observer: observer, logger: logger)
        case .direct(let provider):
            let snapshot = policy.snapshot
            guard let key = resolution.key else { throw .keyRequired(.noKey) }
            guard let endpoint = snapshot.bundle.providers[provider] else { throw .configuration(.unpinnedEndpoint) }
            let pacer = policy.pacing.pacer(
                provider: provider,
                key: key,
                maxInFlight: snapshot.bundle.features.adDetection.window.maxInFlight
            )
            let removals = removals
            let onRemoval: @Sendable (AnalysisKeyRequiredReason) -> Void = { reason in removals.record(reason, runID: runID) }
            // Checked again once the pacer admits each send.
            let dispatchCheck = AnalysisKeyPresenceGuardTransport.dispatchCheck(
                provider: provider,
                keyDigest: key.digest,
                keys: keys,
                onRemoval: onRemoval
            )
            let providerTransport: any AnalysisProviderTransport
            do throws(AnalysisProviderConfigurationError) {
                switch provider {
                case .google:
                    providerTransport = try GeminiAnalysisTransport(
                        endpoint: endpoint, key: key, client: client, pacer: pacer, observer: observer, logger: logger,
                        preDispatch: dispatchCheck
                    )
                case .openai:
                    providerTransport = try OpenAIAnalysisTransport(
                        endpoint: endpoint, key: key, client: client, pacer: pacer, observer: observer, logger: logger,
                        preDispatch: dispatchCheck
                    )
                }
            } catch {
                throw .configuration(error)
            }
            return AnalysisKeyPresenceGuardTransport(
                inner: providerTransport,
                provider: provider,
                keyDigest: key.digest,
                keys: keys,
                observer: observer,
                onRemoval: onRemoval
            )
        }
    }
}

/// Fans one run's send records out to several observers.
nonisolated struct AnalysisSendObservers: AnalysisProviderSendObserver {
    let observers: [any AnalysisProviderSendObserver]

    func record(_ send: AnalysisProviderSendRecord) {
        for observer in observers { observer.record(send) }
    }
}
