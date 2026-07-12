import DeviceCheck
import Foundation

struct AdAnalysisBackendConfiguration: Sendable {
    let workerBaseURL: URL
    let authentication: AdAnalysisBackendAuthentication
    let isEnabled: Bool

    var analysisUnavailableMessage: String? {
        analysisUnavailableMessage(appAttestSupported: DCAppAttestService.shared.isSupported)
    }

    func analysisUnavailableMessage(appAttestSupported: Bool) -> String? {
        guard isEnabled else {
            return EpisodeAdAnalysisError.clientDisabled.localizedDescription
        }
        switch authentication {
        #if DEBUG
        case .bearer:
            return nil
        #endif
        case .appAttest:
            return appAttestSupported
                ? nil
                : EpisodeAdAnalysisError.appAttestUnavailable.localizedDescription
        }
    }

    nonisolated static let current: Self = {
        #if INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        return prodStaging
        #elseif DEBUG
        return debug(environment: ProcessInfo.processInfo.environment)
        #else
        return production
        #endif
    }()

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
