import Foundation
import Observation
import OpenCastAnalysis

@Observable
final class AnalysisKeyRequiredPresenter {
    private(set) var request: AnalysisKeyRequiredRequest?

    func present(feature: AnalysisFeature, trialStatus: AnalysisTrialStatus) {
        request = AnalysisKeyRequiredRequest(id: UUID(), feature: feature, trialStatus: trialStatus)
    }

    /// A request presented since the screen for `id` opened stays.
    func dismiss(id: UUID) {
        guard request?.id == id else {
            return
        }
        request = nil
    }
}
