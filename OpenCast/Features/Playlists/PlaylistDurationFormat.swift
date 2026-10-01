import Foundation

/// Playlist durations in whole minutes: "6h 20m" on screen and
/// "6 hours 20 minutes" for VoiceOver. A positive duration never shows as
/// zero minutes.
nonisolated enum PlaylistDurationFormat {
    static func short(_ duration: TimeInterval) -> String {
        let (hours, minutes) = components(duration)
        if hours > 0, minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }

    static func spoken(_ duration: TimeInterval) -> String {
        let (hours, minutes) = components(duration)
        let hoursText = hours == 1 ? "1 hour" : "\(hours) hours"
        let minutesText = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        if hours > 0, minutes > 0 {
            return "\(hoursText) \(minutesText)"
        }
        if hours > 0 {
            return hoursText
        }
        return minutesText
    }

    private static func components(_ duration: TimeInterval) -> (hours: Int, minutes: Int) {
        guard duration > 0, duration.isFinite else {
            return (0, 0)
        }
        let totalMinutes = max(Int((duration / 60).rounded()), 1)
        return (totalMinutes / 60, totalMinutes % 60)
    }
}
