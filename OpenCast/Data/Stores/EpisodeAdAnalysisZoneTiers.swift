import Foundation
import OpenCastPlayback

/// Confidence-tiered skip zones: `autoSkip` zones drive `PlaybackAdSkipPolicy`;
/// `displayOnly` zones render dimmed on the timeline and never auto-fire.
struct EpisodeAdAnalysisZoneTiers: Equatable {
    let autoSkip: [PlaybackSkipZone]
    let displayOnly: [PlaybackSkipZone]

    static let empty = EpisodeAdAnalysisZoneTiers(autoSkip: [], displayOnly: [])
}
