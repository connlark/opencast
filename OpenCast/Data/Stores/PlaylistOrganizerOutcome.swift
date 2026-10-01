import Foundation

/// What one Make a Playlist request produced, worded for this feature rather
/// than through `TranscriptIntelligenceFailure.userMessage`.
nonisolated enum PlaylistOrganizerOutcome: Equatable, Sendable {
    case proposals([PlaylistProposalDraft], scope: PlaylistOrganizerScope)
    case empty(scope: PlaylistOrganizerScope)
    case declined
    case limitReached(resetDate: Date?)
    case offline
    case serviceUnavailable
    case timedOut
    case malformed
    case tooLong
    /// Never shown; the sheet returns to the form.
    case cancelled
    case failed(String)

    func message(for mode: PlaylistOrganizerMode) -> String? {
        switch self {
        case .proposals, .cancelled:
            nil
        case .empty:
            mode == .prompted
                ? "No matching episodes. Try different words, or suggest groups instead."
                : "No groups stood out in this show. Ask for a specific playlist instead."
        case .declined:
            mode == .prompted
                ? "Apple’s model declined this request. Try different words, or suggest groups instead."
                : "Apple’s model declined this request. Try again, or ask for a specific playlist instead."
        case .limitReached:
            "Apple Intelligence usage limit reached. Try again later."
        case .offline:
            "You’re offline. Make a Playlist needs a connection to Apple’s Private Cloud Compute."
        case .serviceUnavailable:
            "Apple’s Private Cloud Compute is unavailable right now."
        case .timedOut:
            "Apple’s model took too long to respond."
        case .malformed:
            "Couldn’t read the model’s answer."
        case .tooLong:
            "This show’s episode list is too long for Apple’s model."
        case .failed(let message):
            message
        }
    }

    var offersRetry: Bool {
        switch self {
        case .declined, .offline, .serviceUnavailable, .timedOut, .malformed, .failed:
            true
        case .proposals, .empty, .limitReached, .tooLong, .cancelled:
            false
        }
    }

    var offersOtherMode: Bool {
        switch self {
        case .declined, .empty:
            true
        case .proposals, .limitReached, .offline, .serviceUnavailable, .timedOut, .malformed, .tooLong,
             .cancelled, .failed:
            false
        }
    }
}
