import Foundation
import OpenCastAnalysis

nonisolated struct AnalysisKeyRequiredRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    let feature: AnalysisFeature
    let trialStatus: AnalysisTrialStatus
}
