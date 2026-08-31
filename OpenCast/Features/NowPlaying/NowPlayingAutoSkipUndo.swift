import Foundation
import OpenCastPlayback

/// Resolves the "Skipped promo" pill's undo action: the seek target is the
/// skipped zone's start, and the seek lands with `.scrub` intent so
/// `PlaybackAdSkipPolicy` disarms that zone until playback exits it (plays
/// through once, re-arms after exit).
enum NowPlayingAutoSkipUndo {
    nonisolated static let seekIntent: PlaybackSeekIntent = .scrub
    /// A seek to exactly `zone.startTime` can land a frame *before* the zone
    /// (AVPlayer landing wobble), so the `.scrub` landing misses the zone, no
    /// disarm happens, and the very next tick re-skips — measured live on the
    /// original bug-report episode (undo landed at 0:50 against a 0:50.x zone
    /// start and instantly re-skipped to 2:10). Land safely inside instead.
    nonisolated static let landingMargin: TimeInterval = 0.5

    nonisolated static func seekTarget(
        for event: PlaybackAutoSkipEvent?,
        zones: [PlaybackSkipZone]
    ) -> TimeInterval? {
        guard let event,
              let zone = zones.first(where: { $0.id == event.zoneID })
        else {
            return nil
        }

        return min(zone.startTime + landingMargin, (zone.startTime + zone.endTime) / 2)
    }
}
