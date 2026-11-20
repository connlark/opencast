import DeviceCheck
import Foundation

nonisolated enum TrialProxyAuthentication: Sendable, Equatable {
    #if DEBUG
    /// For simulators, which cannot attest.
    case bearer(clientToken: String)
    #endif
    case appAttest(keychainService: String)
}

nonisolated struct TrialProxyBackendConfiguration: Sendable, Equatable {
    let baseURL: URL
    let authentication: TrialProxyAuthentication

    var canAuthenticate: Bool {
        canAuthenticate(appAttestSupported: DCAppAttestService.shared.isSupported)
    }

    private func canAuthenticate(appAttestSupported: Bool) -> Bool {
        switch authentication {
        #if DEBUG
        case .bearer: true
        #endif
        case .appAttest: appAttestSupported
        }
    }

    static let developmentBaseURL = URL(string: "https://trial-proxy.example.com/development")!
    static let prodStagingBaseURL = URL(string: "https://trial-proxy.example.com/prod-staging")!

    static let prodStaging = Self(
        baseURL: prodStagingBaseURL,
        authentication: .appAttest(keychainService: TrialProxyAppAttestKeychainServices.prodStaging)
    )

    static func resolve(
        trialEndpoint: URL,
        routing: AnalysisBackendRouting = .currentBuild,
        storeEnvironment: @Sendable () async throws -> RemoteTranscriptionStoreEnvironment
    ) async -> Self? {
        #if INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        if routing == .currentBuild { return prodStaging }
        #elseif DEBUG
        if routing == .currentBuild { return debug(environment: ProcessInfo.processInfo.environment) }
        #endif
        guard let environment = try? await storeEnvironment() else { return nil }
        return release(for: environment, trialEndpoint: trialEndpoint)
    }

    #if DEBUG
    static func debug(environment: [String: String]) -> Self {
        let baseURL = environment["OPENCAST_TRIAL_PROXY_BASE_URL"].flatMap(originURL) ?? developmentBaseURL
        if let clientToken = environment["OPENCAST_TRIAL_PROXY_CLIENT_TOKEN"].flatMap(\.trimmedNonEmpty) {
            return Self(baseURL: baseURL, authentication: .bearer(clientToken: clientToken))
        }
        return Self(
            baseURL: baseURL,
            authentication: .appAttest(keychainService: TrialProxyAppAttestKeychainServices.development)
        )
    }
    #endif

    static func release(for environment: RemoteTranscriptionStoreEnvironment, trialEndpoint: URL) -> Self? {
        switch environment {
        case .production:
            guard let baseURL = originURL(trialEndpoint.absoluteString), baseURL.scheme == "https" else { return nil }
            return Self(
                baseURL: baseURL,
                authentication: .appAttest(keychainService: TrialProxyAppAttestKeychainServices.production)
            )
        case .sandbox, .xcode:
            return prodStaging
        case .unknown:
            return nil
        }
    }

    /// No path, query or user info: the request binding signs the bare route path.
    static func originURL(_ value: String) -> URL? {
        guard let trimmed = value.trimmedNonEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil
        else {
            return nil
        }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = components.port
        return origin.url
    }
}
