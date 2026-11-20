import DeviceCheck
import Foundation
import OpenCastAnalysisProviders
import Synchronization

nonisolated final class AnalysisTrialConnection: AnalysisTrialConnecting {
    static let statusTimeoutSeconds = 15.0
    static let statusMaximumBytes = 16 * 1024

    private let routing: AnalysisBackendRouting
    private let storeEnvironment: @Sendable () async throws -> RemoteTranscriptionStoreEnvironment
    private let fixtureStatus: AnalysisTrialProxyStatus?
    private let isFixture: Bool
    private let resolved = Mutex<TrialProxyBackendConfiguration?>(nil)

    init(
        routing: AnalysisBackendRouting = .currentBuild,
        storeEnvironment: @escaping @Sendable () async throws -> RemoteTranscriptionStoreEnvironment =
            RemoteTranscriptionAppTransactionProvider.currentEnvironment,
        fixtureStatus: AnalysisTrialProxyStatus? = nil,
        isFixture: Bool = false
    ) {
        self.routing = routing
        self.storeEnvironment = storeEnvironment
        self.fixtureStatus = fixtureStatus
        self.isFixture = isFixture
    }

    var isConfigured: Bool {
        if isFixture { return true }
        #if DEBUG && !INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        return TrialProxyBackendConfiguration.debug(environment: ProcessInfo.processInfo.environment).canAuthenticate
        #else
        return DCAppAttestService.shared.isSupported
        #endif
    }

    /// Unlike `isConfigured`, resolves the configuration: in a release build an unknown store
    /// environment has no route. Makes no request to opencast.
    func isReachable(trialEndpoint: URL) async -> Bool {
        if isFixture { return true }
        return await configuration(trialEndpoint: trialEndpoint)?.canAuthenticate ?? false
    }

    func configuration(
        trialEndpoint: URL,
        storeEnvironment: (@Sendable () async throws -> RemoteTranscriptionStoreEnvironment)? = nil
    ) async -> TrialProxyBackendConfiguration? {
        if let cached = resolved.withLock({ $0 }) { return cached }
        let configuration = await TrialProxyBackendConfiguration.resolve(
            trialEndpoint: trialEndpoint,
            routing: routing,
            storeEnvironment: storeEnvironment ?? self.storeEnvironment
        )
        return resolved.withLock { cached in
            if let cached { return cached }
            if let configuration { cached = configuration }
            return configuration
        }
    }

    func exchange(trialEndpoint: URL) async -> (any AnalysisTrialProxyExchange)? {
        if isFixture { return AnalysisUITestTrialProxyExchange() }
        guard let configuration = await configuration(trialEndpoint: trialEndpoint),
              configuration.canAuthenticate
        else {
            return nil
        }
        switch configuration.authentication {
        #if DEBUG
        case .bearer(let clientToken):
            return BearerTrialProxyExchange(baseURL: configuration.baseURL, clientToken: clientToken)
        #endif
        case .appAttest(let keychainService):
            return AppAttestTrialProxyExchange(baseURL: configuration.baseURL, keychainService: keychainService)
        }
    }

    func fetchStatus(trialEndpoint: URL) async -> AnalysisTrialProxyStatus? {
        if isFixture { return fixtureStatus }
        guard let exchange = await exchange(trialEndpoint: trialEndpoint),
              let response = try? await exchange.post(
                  path: TrialProxyAnalysisTransport.statusPath,
                  payloadText: "{}",
                  timeoutSeconds: Self.statusTimeoutSeconds,
                  maximumBodyBytes: Self.statusMaximumBytes
              ),
              (200..<300).contains(response.status)
        else {
            return nil
        }
        return AnalysisTrialProxyStatus.decode(response.body)
    }
}

/// Stands in for the route only; it is never posted to.
nonisolated struct AnalysisUITestTrialProxyExchange: AnalysisTrialProxyExchange {
    func post(
        path: String,
        payloadText: String,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        throw .network
    }
}
