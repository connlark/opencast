import Foundation

enum EpisodeAdAnalysisError: LocalizedError, Sendable, Equatable {
    case clientDisabled
    case appAttestUnavailable
    case transcriptNotCompleted
    case analysisDocumentMissing
    case anotherJobActive
    case analysisTimedOut

    var errorDescription: String? {
        switch self {
        case .clientDisabled:
            "Promo/ad analysis is disabled in this build."
        case .appAttestUnavailable:
            "Promo/ad analysis requires App Attest on a physical device."
        case .transcriptNotCompleted:
            "Complete the transcript before analyzing promos and ads."
        case .analysisDocumentMissing:
            "The promo/ad analysis file could not be found."
        case .anotherJobActive:
            "Finish the active promo/ad analysis before starting another one."
        case .analysisTimedOut:
            "Promo/ad analysis took too long. Try again."
        }
    }
}
