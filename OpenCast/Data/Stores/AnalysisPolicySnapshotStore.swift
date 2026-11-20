import Foundation
import Observation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import OpenCastTranscription

@Observable
final class AnalysisPolicySnapshotStore {
    private(set) var snapshot: AnalysisPolicySnapshot
    /// One per app session, so a rate limit one run meets paces every later run on the same key.
    @ObservationIgnored let pacing: AnalysisKeyPacing
    @ObservationIgnored private let loader: AnalysisPolicyLoader?

    init(
        loader: AnalysisPolicyLoader?,
        pacing: AnalysisKeyPacing = AnalysisKeyPacing(),
        initial: AnalysisPolicySnapshot = .baked
    ) {
        self.loader = loader
        self.pacing = pacing
        snapshot = initial
    }

    /// Until the gateway's policy route serves a bundle, every refresh fails and the baked copy
    /// stands with `fallbackReason` set; that is expected.
    static func live() -> AnalysisPolicySnapshotStore {
        AnalysisPolicySnapshotStore(loader: AnalysisPolicyLoader(
            appBuild: OpenCastAppVersion.buildNumber ?? 0,
            endpoint: AnalysisPolicyEndpoint(baseURL: OpenCastRemoteModelGatewayConfiguration.defaultBaseURL)
        ))
    }

    static func fixed(_ snapshot: AnalysisPolicySnapshot) -> AnalysisPolicySnapshotStore {
        AnalysisPolicySnapshotStore(loader: nil, initial: snapshot)
    }

    func refreshIfDue() async {
        guard let loader else {
            return
        }
        // The cache first, without the network, so a downloaded bundle is
        // active before a slow or failing fetch returns.
        let cached = await loader.snapshot()
        adopt(cached)
        let refreshed = await loader.refreshIfDue()
        adopt(refreshed)
    }

    private func adopt(_ snapshot: AnalysisPolicySnapshot) {
        guard snapshot != self.snapshot else {
            return
        }
        self.snapshot = snapshot
    }
}
