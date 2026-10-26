import Foundation
import Observation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import OpenCastTranscription

/// The analysis policy the app runs under now, and the key pacers of this
/// app session. Starts as the baked copy; `refreshIfDue()` adopts the
/// loader's cached bundle, then fetches when due.
@Observable
final class AnalysisPolicySnapshotStore {
    private(set) var snapshot: AnalysisPolicySnapshot
    /// One per app session; the analysis runs reuse it, so a rate limit one
    /// run meets paces every later run on the same key.
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

    /// The model gateway's policy route. Until that route serves a bundle,
    /// every refresh fails and the snapshot is the baked copy with its
    /// `fallbackReason` set, by design.
    static func live() -> AnalysisPolicySnapshotStore {
        AnalysisPolicySnapshotStore(loader: AnalysisPolicyLoader(
            appBuild: OpenCastAppVersion.buildNumber ?? 0,
            endpoint: AnalysisPolicyEndpoint(baseURL: OpenCastRemoteModelGatewayConfiguration.defaultBaseURL)
        ))
    }

    /// UI tests and previews: a fixed snapshot that never fetches.
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
