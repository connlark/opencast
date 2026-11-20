import Foundation
import OpenCastPlayback

/// The undo seek uses `.scrub` so the skip policy disarms the zone until playback leaves it.
enum NowPlayingAutoSkipUndo {
    nonisolated static let seekIntent: PlaybackSeekIntent = .scrub
    /// AVPlayer can land a seek to exactly `zone.startTime` a frame before the zone, so the
    /// `.scrub` landing misses it and the next tick re-skips. Land inside instead.
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
