import Foundation
import OpenCastAnalysis

/// One request to show the key screen: the feature that needs a key and the
/// trial status that explains why.
nonisolated struct AnalysisKeyRequiredRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    let feature: AnalysisFeature
    let trialStatus: AnalysisTrialStatus
}
