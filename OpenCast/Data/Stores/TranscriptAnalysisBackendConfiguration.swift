import DeviceCheck
import Foundation

struct TranscriptAnalysisBackendConfiguration: Sendable {
    let workerBaseURL: URL
    let authentication: TranscriptAnalysisBackendAuthentication
    let isEnabled: Bool

    var analysisUnavailableMessage: String? {
        analysisUnavailableMessage(appAttestSupported: DCAppAttestService.shared.isSupported)
    }

    func analysisUnavailableMessage(appAttestSupported: Bool) -> String? {
        guard isEnabled else {
            return EpisodeTranscriptAnalysisError.clientDisabled.localizedDescription
        }
        switch authentication {
        #if DEBUG
        case .bearer:
            return nil
        #endif
        case .appAttest:
            return appAttestSupported
                ? nil
                : EpisodeTranscriptAnalysisError.appAttestUnavailable.localizedDescription
        }
    }

    nonisolated static let current: Self = {
        #if INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        return prodStaging
        #elseif DEBUG
        return debug(environment: ProcessInfo.processInfo.environment)
        #else
        // Release code must resolve through `release(for:)`; a bare client
        // cannot safely guess which money/state lane owns the install.
        return disabled
        #endif
    }()

    #if DEBUG
    nonisolated static func debug(environment: [String: String]) -> Self {
        let workerBaseURL = environment["OPENCAST_TRANSCRIPT_ANALYSIS_BASE_URL"]
            .flatMap(absoluteHTTPURL)
            ?? defaultDebugWorkerBaseURL
        if let clientToken = environment["OPENCAST_TRANSCRIPT_ANALYSIS_CLIENT_TOKEN"].flatMap(\.trimmedNonEmpty) {
            return Self(
                workerBaseURL: workerBaseURL,
                authentication: .bearer(clientToken: clientToken),
                isEnabled: true
            )
        }

        return Self(
            workerBaseURL: workerBaseURL,
            authentication: .appAttest(keychainService: TranscriptAnalysisAppAttestKeychainServices.development),
            isEnabled: true
        )
    }
    #endif

    nonisolated static let prodStaging = Self(
        workerBaseURL: URL(string: "https://transcript-analysis.example.com/prod-staging")!,
        authentication: .appAttest(keychainService: TranscriptAnalysisAppAttestKeychainServices.prodStaging),
        isEnabled: true
    )

    nonisolated static let production = Self(
        workerBaseURL: URL(string: "https://transcript-analysis.example.com")!,
        authentication: .appAttest(keychainService: TranscriptAnalysisAppAttestKeychainServices.production),
        isEnabled: true
    )

    /// Release lane routing (RTW precedent): production StoreKit → the
    /// production worker; Sandbox/Xcode (TestFlight) → prod-staging so
    /// sandbox purchases exercise prod-staging billing end-to-end; unknown →
    /// disabled (fail closed — never guess a money lane).
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

    /// Fail-closed configuration for unresolved release environments and
    /// tests.
    nonisolated static let disabled = Self(
        workerBaseURL: defaultDebugWorkerBaseURL,
        authentication: .appAttest(keychainService: TranscriptAnalysisAppAttestKeychainServices.development),
        isEnabled: false
    )

    /// Release lanes all authenticate with App Attest, so the synchronous
    /// start-gate message is lane-independent; the concrete lane resolves
    /// per-request in `TranscriptAnalysisRoutedAPIClient`.
    static var releaseAnalysisUnavailableMessage: String? {
        production.analysisUnavailableMessage
    }

    nonisolated private static let defaultDebugWorkerBaseURL = URL(string: "https://transcript-analysis.example.com/development")!

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
