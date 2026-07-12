import Foundation
import OpenCastPlayback

struct EpisodeAdSpanSummary: Equatable {
    let segmentCount: Int
    let totalDuration: TimeInterval

    static func make(zoneTiers: EpisodeAdAnalysisZoneTiers) -> EpisodeAdSpanSummary? {
        let zones = zoneTiers.autoSkip + zoneTiers.displayOnly
        guard !zones.isEmpty else {
            return nil
        }

        let totalDuration = zones.reduce(0.0) { $0 + max($1.endTime - $1.startTime, 0) }
        return EpisodeAdSpanSummary(segmentCount: zones.count, totalDuration: totalDuration)
    }

    var caption: String {
        let segments = segmentCount == 1 ? "1 ad segment" : "\(segmentCount) ad segments"
        return "\(segments) · \(Self.formattedDuration(totalDuration))"
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        }
        return "\(seconds)s"
    }
}
