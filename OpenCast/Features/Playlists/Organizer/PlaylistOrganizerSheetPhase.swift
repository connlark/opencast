import Foundation

/// The organizer sheet's screen states: the request form, the request in
/// flight, and what it produced.
enum PlaylistOrganizerSheetPhase: Equatable {
    case request
    case loading(startedAt: Date)
    case proposals
    case empty
    case outcome(PlaylistOrganizerOutcome)
    case unavailable(TranscriptIntelligenceAvailability)
}
