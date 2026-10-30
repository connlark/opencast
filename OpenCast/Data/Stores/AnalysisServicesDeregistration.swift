import Foundation
import OpenCastAnalysisProviders
import Synchronization

nonisolated struct AnalysisServicesDeregistration: Sendable {
    enum Slot: String, CaseIterable, Sendable {
        case transcriptAnalysis
        case adAnalysis
        case remoteTranscription
        case trialProxy
    }

    enum Outcome: Sendable {
        case notRegistered
        case deregistered
        case configurationUnavailable
        case busy
        case failed(any Error)
    }

    typealias Resolver = @Sendable (AnalysisServicesEnvironmentLookup) async -> AppAttestInstallDeregistration?
    typealias Deadline = @Sendable (
        Double, @escaping @Sendable () async throws -> Outcome
    ) async throws -> Outcome

    private let slots: [Slot: Resolver]
    private let storeEnvironment: AnalysisServicesEnvironmentLookup.Provider
    private let timeoutSeconds: Double
    private let deadline: Deadline

    init(
        slots: [Slot: Resolver],
        storeEnvironment: @escaping AnalysisServicesEnvironmentLookup.Provider = RemoteTranscriptionAppTransactionProvider.currentEnvironment,
        timeoutSeconds: Double = 15,
        deadline: @escaping Deadline = { seconds, operation in
            try await TrialProxyDeadline.run(seconds: seconds, operation)
        }
    ) {
        self.slots = slots
        self.storeEnvironment = storeEnvironment
        self.timeoutSeconds = timeoutSeconds
        self.deadline = deadline
    }

    func run() async -> [Slot: Outcome] {
        let lookup = AnalysisServicesEnvironmentLookup(provider: storeEnvironment)
        let outcomes = await withTaskGroup(of: (Slot, Outcome).self) { group in
            for (slot, resolve) in slots {
                group.addTask {
                    let resolved = Mutex<AppAttestInstallDeregistration?>(nil)
                    do {
                        let outcome = try await deadline(timeoutSeconds) {
                            guard let client = await resolve(lookup) else { return .configurationUnavailable }
                            try Task.checkCancellation()
                            resolved.withLock { $0 = client }
                            return switch try await client.deregisterIfRegistered() {
                            case .notRegistered: .notRegistered
                            case .deregistered: .deregistered
                            }
                        }
                        return (slot, outcome)
                    } catch {
                        if resolved.withLock({ $0?.isWaitingForRegistration == true }) {
                            return (slot, .busy)
                        }
                        return (slot, .failed(error))
                    }
                }
            }
            var outcomes: [Slot: Outcome] = [:]
            for await (slot, outcome) in group { outcomes[slot] = outcome }
            return outcomes
        }
        await lookup.cancel()
        return outcomes
    }

    static func live(
        routing: AnalysisBackendRouting = .currentBuild,
        trialConnection: AnalysisTrialConnection,
        trialEndpoint: @escaping @MainActor @Sendable () -> URL,
        storeEnvironment: @escaping AnalysisServicesEnvironmentLookup.Provider = RemoteTranscriptionAppTransactionProvider.currentEnvironment,
        transport: any AppAttestHTTPTransport = URLSession.shared
    ) -> Self {
        Self(slots: [
            .transcriptAnalysis: { lookup in
                guard let configuration = await TranscriptAnalysisBackendConfiguration.resolve(
                    routing: routing,
                    storeEnvironment: { try await lookup.environment() }
                ) else { return nil }
                return transcriptAnalysis(configuration, transport: transport)
            },
            .adAnalysis: { lookup in
                guard let configuration = await AdAnalysisBackendConfiguration.resolve(
                    routing: routing,
                    storeEnvironment: { try await lookup.environment() }
                ) else { return nil }
                return adAnalysis(configuration, transport: transport)
            },
            .remoteTranscription: { lookup in
                guard let configuration = await RemoteTranscriptionBackendConfiguration.resolve(
                    routing: routing,
                    storeEnvironment: { try await lookup.environment() }
                ) else { return nil }
                return remoteTranscription(configuration, transport: transport)
            },
            .trialProxy: { lookup in
                guard let configuration = await trialConnection.configuration(
                    trialEndpoint: trialEndpoint(),
                    storeEnvironment: { try await lookup.environment() }
                ) else { return nil }
                return trialProxy(configuration, transport: transport)
            }
        ], storeEnvironment: storeEnvironment)
    }

    static func transcriptAnalysis(_ configuration: TranscriptAnalysisBackendConfiguration, transport: any AppAttestHTTPTransport = URLSession.shared) -> AppAttestInstallDeregistration? {
        guard case .appAttest(let service) = configuration.authentication else { return nil }
        return .init(baseURL: configuration.workerBaseURL, keychainService: service, transport: transport, keepsInstallID: false)
    }

    static func adAnalysis(_ configuration: AdAnalysisBackendConfiguration, transport: any AppAttestHTTPTransport = URLSession.shared) -> AppAttestInstallDeregistration? {
        guard case .appAttest(let service) = configuration.authentication else { return nil }
        return .init(baseURL: configuration.workerBaseURL, keychainService: service, transport: transport, keepsInstallID: false)
    }

    static func remoteTranscription(_ configuration: RemoteTranscriptionBackendConfiguration, transport: any AppAttestHTTPTransport = URLSession.shared) -> AppAttestInstallDeregistration? {
        guard case .appAttest(let service) = configuration.authentication else { return nil }
        return .init(baseURL: configuration.workerBaseURL, keychainService: service, transport: transport, keepsInstallID: false)
    }

    static func trialProxy(_ configuration: TrialProxyBackendConfiguration, transport: any AppAttestHTTPTransport = URLSession.shared) -> AppAttestInstallDeregistration? {
        guard case .appAttest(let service) = configuration.authentication else { return nil }
        return .init(baseURL: configuration.baseURL, keychainService: service, transport: transport, keepsInstallID: true)
    }
}
