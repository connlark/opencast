import Foundation
import Observation
import OpenCastAnalysis

/// The key screen's request: the analysis route presents it when a feature
/// has no key and no trial analyses left, and the root shows the screen.
@Observable
final class AnalysisKeyRequiredPresenter {
    private(set) var request: AnalysisKeyRequiredRequest?

    func present(feature: AnalysisFeature, trialStatus: AnalysisTrialStatus) {
        request = AnalysisKeyRequiredRequest(id: UUID(), feature: feature, trialStatus: trialStatus)
    }

    /// Called on every dismissal path. A request presented since the screen
    /// for `id` opened stays.
    func dismiss(id: UUID) {
        guard request?.id == id else {
            return
        }
        request = nil
    }
}
