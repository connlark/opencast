import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

nonisolated enum AnalysisTransportFactoryError: Error, Sendable, Hashable {
    case keyRequired(AnalysisKeyRequiredReason)
    case configuration(AnalysisProviderConfigurationError)
}

final class AnalysisTransportFactory {
    private let policy: AnalysisPolicySnapshotStore
    private let runs: AnalysisRunRecordStore
    private let keys: any AnalysisProviderKeyStoring
    private let removals = AnalysisKeyRemovalLog()
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

    func keyRemoval(runID: String) -> AnalysisKeyRequiredReason? {
        removals.reason(runID: runID)
    }

    func keyChange(provider: AnalysisProvider, keyDigest: Data) -> AnalysisKeyRequiredReason? {
        AnalysisKeyPresenceGuardTransport.removal(provider: provider, keyDigest: keyDigest, keys: keys)
    }

    func checkTier(key: AnalysisProviderKey) async -> AnalysisTierCheckResult {
        if let fixture { return fixture.tierAnswer }
        guard let endpoint = policy.snapshot.bundle.providers[.google],
              let transport = try? GeminiAnalysisTransport(
                  endpoint: endpoint,
                  key: key,
                  client: client,
                  logger: RedactingLogger(category: "AnalysisRun")
              )
        else {
            return .inconclusive
        }
        return await transport.checkTier()
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
                        preDispatch: dispatchCheck, freeTierIsFinal: resolution.freeTierHandover
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

nonisolated struct AnalysisSendObservers: AnalysisProviderSendObserver {
    let observers: [any AnalysisProviderSendObserver]

    func record(_ send: AnalysisProviderSendRecord) {
        for observer in observers { observer.record(send) }
    }
}
