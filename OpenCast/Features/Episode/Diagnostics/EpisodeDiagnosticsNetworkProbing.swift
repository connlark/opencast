import Foundation

nonisolated protocol EpisodeDiagnosticsNetworkProbing: Sendable {
    func headProbe(of url: URL) async -> EpisodeDiagnosticsHeadProbe
}
