import Foundation

enum EpisodePipelineStepStatus: Equatable {
    case waiting
    case running(fraction: Double?, detail: String?)
    case done
    case failed(message: String)

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}
