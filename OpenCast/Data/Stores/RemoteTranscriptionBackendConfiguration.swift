import DeviceCheck
import Foundation

/// Backend selection for the remote transcription lanes. DEBUG builds use
/// the development lane. Release builds resolve from AppTransaction before
/// constructing a client: production StoreKit uses the production lane,
/// Sandbox/Xcode uses prod-staging, and unknown environments fail closed.
struct RemoteTranscriptionBackendConfiguration: Sendable {
    let workerBaseURL: URL
    let authentication: RemoteTranscriptionBackendAuthentication
    let isEnabled: Bool
    /// Purchase-backend lanes require the verified AppTransaction JWS on
    /// every bootstrap; the development lane ignores identity entirely.
    let requiresAppTransaction: Bool

    nonisolated static let current: Self = {
        #if DEBUG
        return debug(environment: ProcessInfo.processInfo.environment)
        #else
        // Release code must resolve through `release(for:)`; a bare client
        // cannot safely guess which money/state lane owns the install.
        return disabled
        #endif
    }()

    nonisolated static let developmentWorkerBaseURL =
        URL(string: "https://remote-transcription.example.com/development")!

    nonisolated static let prodStagingWorkerBaseURL =
        URL(string: "https://remote-transcription.example.com/prod-staging")!

    nonisolated static let productionWorkerBaseURL =
        URL(string: "https://remote-transcription.example.com")!

    #if DEBUG
    nonisolated static func debug(environment: [String: String]) -> Self {
        let workerBaseURL = environment["OPENCAST_REMOTE_TRANSCRIPTION_BASE_URL"]
            .flatMap(URL.init(string:))
            .flatMap { url in url.scheme?.hasPrefix("http") == true ? url : nil }
            ?? developmentWorkerBaseURL
        if let clientToken = environment["OPENCAST_REMOTE_TRANSCRIPTION_CLIENT_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           clientToken.isEmpty == false {
            return Self(
                workerBaseURL: workerBaseURL,
                authentication: .bearer(clientToken: clientToken),
                isEnabled: true,
                requiresAppTransaction: false
            )
        }

        return Self(
            workerBaseURL: workerBaseURL,
            authentication: .appAttest(
                keychainService: RemoteTranscriptionAppAttestKeychainServices.development
            ),
            isEnabled: true,
            requiresAppTransaction: false
        )
    }
    #endif

    /// Review/test lane: production App Attest + Sandbox/Xcode StoreKit.
    nonisolated static let prodStaging = Self(
        workerBaseURL: prodStagingWorkerBaseURL,
        authentication: .appAttest(
            keychainService: RemoteTranscriptionAppAttestKeychainServices.prodStaging
        ),
        isEnabled: true,
        requiresAppTransaction: true
    )

    /// Real-customer lane: isolated App Attest credentials and production
    /// StoreKit state behind the custom domain.
    nonisolated static let production = Self(
        workerBaseURL: productionWorkerBaseURL,
        authentication: .appAttest(
            keychainService: RemoteTranscriptionAppAttestKeychainServices.production
        ),
        isEnabled: true,
        requiresAppTransaction: true
    )

    nonisolated static func release(
        for environment: RemoteTranscriptionStoreEnvironment
    ) -> Self {
        switch environment {
        case .production:
            production
        case .sandbox, .xcode:
            prodStaging
        case .unknown:
            disabled
        }
    }

    /// Fail-closed configuration kept for tests and kill-switch fallbacks.
    nonisolated static let disabled = Self(
        workerBaseURL: developmentWorkerBaseURL,
        authentication: .appAttest(
            keychainService: RemoteTranscriptionAppAttestKeychainServices.development
        ),
        isEnabled: false,
        requiresAppTransaction: false
    )
}
