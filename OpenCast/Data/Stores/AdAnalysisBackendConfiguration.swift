import Foundation

/// Where an earlier build's accepted ad-analysis jobs are read from.
struct AdAnalysisBackendConfiguration: Sendable {
    let workerBaseURL: URL
    let authentication: AdAnalysisBackendAuthentication
    let isEnabled: Bool

    nonisolated static let current: Self = {
        #if INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        return prodStaging
        #elseif DEBUG
        return debug(environment: ProcessInfo.processInfo.environment)
        #else
        return production
        #endif
    }()

    nonisolated static func resolve(
        routing: AnalysisBackendRouting = .currentBuild,
        storeEnvironment: @Sendable () async throws -> RemoteTranscriptionStoreEnvironment
    ) async -> Self? {
        #if INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        if routing == .currentBuild { return prodStaging }
        #elseif DEBUG
        if routing == .currentBuild { return debug(environment: ProcessInfo.processInfo.environment) }
        #endif
        guard let environment = try? await storeEnvironment() else { return nil }
        if case .unknown = environment { return nil }
        return release(for: environment)
    }

    #if DEBUG
    nonisolated static func debug(environment: [String: String]) -> Self {
        let workerBaseURL = environment["OPENCAST_AD_ANALYSIS_BASE_URL"]
            .flatMap(absoluteHTTPURL)
            ?? defaultDebugWorkerBaseURL
        if let clientToken = environment["OPENCAST_AD_ANALYSIS_CLIENT_TOKEN"].flatMap(\.trimmedNonEmpty) {
            return Self(
                workerBaseURL: workerBaseURL,
                authentication: .bearer(clientToken: clientToken),
                isEnabled: true
            )
        }

        return Self(
            workerBaseURL: workerBaseURL,
            authentication: .appAttest(keychainService: AdAnalysisAppAttestKeychainServices.development),
            isEnabled: true
        )
    }
    #endif

    nonisolated static let prodStaging = Self(
        workerBaseURL: URL(string: "https://ad-analysis.example.com/prod-staging")!,
        authentication: .appAttest(keychainService: AdAnalysisAppAttestKeychainServices.prodStaging),
        isEnabled: true
    )

    nonisolated static let production = Self(
        workerBaseURL: URL(string: "https://ad-analysis.example.com")!,
        authentication: .appAttest(keychainService: AdAnalysisAppAttestKeychainServices.production),
        isEnabled: true
    )

    nonisolated static func release(for environment: RemoteTranscriptionStoreEnvironment) -> Self? {
        switch environment {
        case .production: production
        case .sandbox, .xcode: prodStaging
        case .unknown: nil
        }
    }

    nonisolated private static let defaultDebugWorkerBaseURL = URL(string: "https://ad-analysis.example.com/development")!

    nonisolated private static func absoluteHTTPURL(_ value: String) -> URL? {
        guard let trimmedValue = value.trimmedNonEmpty,
              let url = URL(string: trimmedValue),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil
        else {
            return nil
        }
        return url
    }
}
