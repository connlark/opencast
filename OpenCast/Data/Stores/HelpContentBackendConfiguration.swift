import Foundation

/// Where the remotely updatable help document comes from. Release builds
/// read the public support host; DEBUG builds honor an http(s) override for
/// `yarn preview`, a kill switch, and stay offline under UI testing unless a
/// run opts in with an explicit URL.
struct HelpContentBackendConfiguration: Sendable {
    let documentURL: URL
    let isEnabled: Bool

    nonisolated static let current: Self = {
        #if DEBUG
        return debug(environment: ProcessInfo.processInfo.environment)
        #else
        return production
        #endif
    }()

    nonisolated static let productionDocumentURL =
        URL(string: "https://support.opencast.mobile/app/help/v1.json")!

    #if DEBUG
    nonisolated static func debug(environment: [String: String]) -> Self {
        let overrideURL = environment["OPENCAST_HELP_CONTENT_URL"]
            .flatMap(URL.init(string:))
            .flatMap { url in url.scheme?.hasPrefix("http") == true ? url : nil }
        if environment["OPENCAST_UI_TESTING"] == "1", overrideURL == nil {
            return Self(documentURL: productionDocumentURL, isEnabled: false)
        }
        return Self(
            documentURL: overrideURL ?? productionDocumentURL,
            isEnabled: environment["OPENCAST_HELP_CONTENT_DISABLED"] != "1"
        )
    }
    #endif

    nonisolated static let production = Self(
        documentURL: productionDocumentURL,
        isEnabled: true
    )
}
