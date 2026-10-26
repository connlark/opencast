import DeviceCheck
import Foundation
import OpenCastAnalysisProviders
import Synchronization

/// Reaches the trial service for this build: resolves its configuration
/// once, builds the exchange that signs for it, and reads the install's
/// trial status. Under UI testing it never touches the network.
nonisolated final class AnalysisTrialConnection: AnalysisTrialConnecting {
    static let statusTimeoutSeconds = 15.0
    static let statusMaximumBytes = 16 * 1024

    private let storeEnvironment: @Sendable () async throws -> RemoteTranscriptionStoreEnvironment
    /// UI tests: the seeded status, answered without a request.
    private let fixtureStatus: AnalysisTrialProxyStatus?
    private let isFixture: Bool
    private let resolved = Mutex<TrialProxyBackendConfiguration??>(nil)

    init(
        storeEnvironment: @escaping @Sendable () async throws -> RemoteTranscriptionStoreEnvironment =
            RemoteTranscriptionAppTransactionProvider.currentEnvironment,
        fixtureStatus: AnalysisTrialProxyStatus? = nil,
        isFixture: Bool = false
    ) {
        self.storeEnvironment = storeEnvironment
        self.fixtureStatus = fixtureStatus
        self.isFixture = isFixture
    }

    /// Whether this build and device can use a trial route at all, without
    /// any request: a Debug build with the operator bearer, or a device
    /// that can attest.
    var isConfigured: Bool {
        if isFixture { return true }
        #if DEBUG && !INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        return TrialProxyBackendConfiguration.debug(environment: ProcessInfo.processInfo.environment).canAuthenticate
        #else
        return DCAppAttestService.shared.isSupported
        #endif
    }

    func configuration(trialEndpoint: URL) async -> TrialProxyBackendConfiguration? {
        if let cached = resolved.withLock({ $0 }) { return cached }
        let configuration = await TrialProxyBackendConfiguration.resolve(
            trialEndpoint: trialEndpoint,
            storeEnvironment: storeEnvironment
        )
        resolved.withLock { $0 = .some(configuration) }
        return configuration
    }

    /// The exchange for this build's deployment, or `nil` when it has no
    /// trial route or this device cannot sign for it.
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

    /// The install's trial status, or `nil` when it could not be read.
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

/// UI tests route trial runs through the fixture transport; this exchange
/// only stands in for the route and is never posted to.
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
