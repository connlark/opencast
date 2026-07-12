import Foundation
import OpenCastPlayback

enum EpisodeAdAnalysisZoneMapper {
    private static let mergeGap: TimeInterval = 1
    /// Spans at or above this confidence auto-skip; spans below render as
    /// dimmed display-only zones (visible, never auto-fire).
    static let autoSkipConfidenceFloor = 0.8

    static func zoneTiers(
        for document: EpisodeAdAnalysisDocument,
        duration: TimeInterval?
    ) -> EpisodeAdAnalysisZoneTiers {
        // Tiers merge internally only: a display-only span must never extend
        // an auto-skip zone (or the floor would silently skip low-confidence
        // audio), so the split happens before any merging.
        let autoSkipSpans = document.spans.filter { $0.confidence >= autoSkipConfidenceFloor }
        let displayOnlySpans = document.spans.filter { $0.confidence < autoSkipConfidenceFloor }
        return EpisodeAdAnalysisZoneTiers(
            autoSkip: mergedZones(for: autoSkipSpans, duration: duration),
            displayOnly: mergedZones(for: displayOnlySpans, duration: duration)
        )
    }

    static func zones(
        for document: EpisodeAdAnalysisDocument,
        duration: TimeInterval?
    ) -> [PlaybackSkipZone] {
        zoneTiers(for: document, duration: duration).autoSkip
    }

    private static func mergedZones(
        for spans: [EpisodeAdAnalysisSpan],
        duration: TimeInterval?
    ) -> [PlaybackSkipZone] {
        let finiteDuration = duration.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        }

        let mappedZones = spans.compactMap { span -> PlaybackSkipZone? in
            guard span.startTime.isFinite, span.endTime.isFinite else {
                return nil
            }

            var startTime = max(0, span.startTime)
            var endTime = max(0, span.endTime)
            if let finiteDuration {
                startTime = min(startTime, finiteDuration)
                endTime = min(endTime, finiteDuration)
            }
            guard endTime > startTime else {
                return nil
            }

            return PlaybackSkipZone(id: span.id, startTime: startTime, endTime: endTime)
        }
        .sorted {
            if $0.startTime == $1.startTime {
                if $0.endTime == $1.endTime {
                    return $0.id < $1.id
                }
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }

        return mappedZones.reduce(into: []) { result, zone in
            guard let last = result.last else {
                result.append(zone)
                return
            }

            if zone.startTime - last.endTime <= Self.mergeGap {
                result[result.endIndex - 1] = PlaybackSkipZone(
                    id: last.id,
                    startTime: last.startTime,
                    endTime: max(last.endTime, zone.endTime)
                )
            } else {
                result.append(zone)
            }
        }
    }
}
