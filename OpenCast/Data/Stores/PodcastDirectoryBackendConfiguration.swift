import Foundation

/// Backend selection for the podcast directory Worker (the Podcast
/// Index supplement). The service is unauthenticated and read-only;
/// DEBUG builds use the development lane with an environment override,
/// release builds use the production custom domain. A disabled or
/// unreachable Worker degrades to the Apple-only experience.
struct PodcastDirectoryBackendConfiguration: Sendable {
    let workerBaseURL: URL
    let isEnabled: Bool

    nonisolated static let current: Self = {
        #if DEBUG
        return debug(environment: ProcessInfo.processInfo.environment)
        #else
        return production
        #endif
    }()

    nonisolated static let developmentWorkerBaseURL =
        URL(string: "https://directory.example.com/development")!

    nonisolated static let prodStagingWorkerBaseURL =
        URL(string: "https://directory.example.com/prod-staging")!

    nonisolated static let productionWorkerBaseURL =
        URL(string: "https://directory.example.com")!

    #if DEBUG
    /// UI tests stay on the deterministic Apple-only path unless a run
    /// opts in with an explicit base URL override.
    nonisolated static func debug(environment: [String: String]) -> Self {
        let overrideURL = environment["OPENCAST_PODCAST_DIRECTORY_BASE_URL"]
            .flatMap(URL.init(string:))
            .flatMap { url in url.scheme?.hasPrefix("http") == true ? url : nil }
        if environment["OPENCAST_UI_TESTING"] == "1", overrideURL == nil {
            return Self(workerBaseURL: developmentWorkerBaseURL, isEnabled: false)
        }
        return Self(
            workerBaseURL: overrideURL ?? developmentWorkerBaseURL,
            isEnabled: environment["OPENCAST_PODCAST_DIRECTORY_DISABLED"] != "1"
        )
    }
    #endif

    nonisolated static let production = Self(
        workerBaseURL: productionWorkerBaseURL,
        isEnabled: true
    )
}
