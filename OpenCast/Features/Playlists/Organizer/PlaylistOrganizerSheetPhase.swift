import Foundation

enum PlaylistOrganizerSheetPhase: Equatable {
    case request
    case loading(startedAt: Date)
    case proposals
    case empty
    case outcome(PlaylistOrganizerOutcome)
    case unavailable(TranscriptIntelligenceAvailability)
}
