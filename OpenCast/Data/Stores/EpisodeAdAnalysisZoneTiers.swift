import Foundation
import OpenCastPlayback

struct EpisodeAdAnalysisZoneTiers: Equatable {
    let autoSkip: [PlaybackSkipZone]
    let displayOnly: [PlaybackSkipZone]

    static let empty = EpisodeAdAnalysisZoneTiers(autoSkip: [], displayOnly: [])
}
