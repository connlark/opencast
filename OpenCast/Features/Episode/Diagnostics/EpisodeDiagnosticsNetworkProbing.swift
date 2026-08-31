import Foundation

/// HEAD-only network probing for the diagnostics sheet; injected so tests
/// can stub transport behavior and prove no probe fires before the sheet
/// opens.
nonisolated protocol EpisodeDiagnosticsNetworkProbing: Sendable {
    func headProbe(of url: URL) async -> EpisodeDiagnosticsHeadProbe
}
