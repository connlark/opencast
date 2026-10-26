import DeviceCheck
import Foundation

/// How this build signs requests to the trial service.
nonisolated enum TrialProxyAuthentication: Sendable, Equatable {
    #if DEBUG
    /// The service's operator bearer, for simulators, which cannot attest.
    case bearer(clientToken: String)
    #endif
    case appAttest(keychainService: String)
}

/// The trial service this build talks to, chosen the way the other
/// analysis services are: Debug builds use the development deployment (or
/// an override), internal builds and TestFlight use prod-staging, and App
/// Store builds use the bundle's trial endpoint. An unknown StoreKit
/// environment has no trial route.
nonisolated struct TrialProxyBackendConfiguration: Sendable, Equatable {
    let baseURL: URL
    let authentication: TrialProxyAuthentication

    /// Whether this device can sign for the service right now.
    var canAuthenticate: Bool {
        canAuthenticate(appAttestSupported: DCAppAttestService.shared.isSupported)
    }

    func canAuthenticate(appAttestSupported: Bool) -> Bool {
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

    /// The configuration for this build. `trialEndpoint` is the bundle's
    /// `trial.endpoint`; `storeEnvironment` is read only by App Store and
    /// TestFlight builds.
    static func resolve(
        trialEndpoint: URL,
        storeEnvironment: @Sendable () async throws -> RemoteTranscriptionStoreEnvironment
    ) async -> Self? {
        #if INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        return prodStaging
        #elseif DEBUG
        return debug(environment: ProcessInfo.processInfo.environment)
        #else
        guard let environment = try? await storeEnvironment() else { return nil }
        return release(for: environment, trialEndpoint: trialEndpoint)
        #endif
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

    /// An absolute http(s) URL with a host and no path, query, fragment or
    /// user info: the request binding signs the bare route path.
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
