import Foundation
import OpenCastPlayback

/// Maps every raw ad span through `EpisodeAdAnalysisZoneMapper` once per
/// candidate duration and records what happened to it — the primary evidence
/// when an outro zone silently clamps or drops near the episode boundary.
/// Span fates come from mapping each span alone through the real mapper, so
/// this never re-derives the clamp rules.
nonisolated struct EpisodeDiagnosticsZoneMatrix: Sendable, Equatable {
    nonisolated struct DurationBasis: Sendable, Equatable {
        var label: String
        var duration: TimeInterval?
    }

    nonisolated enum SpanFate: Sendable, Equatable {
        case preserved
        case clamped(startTime: TimeInterval, endTime: TimeInterval)
        case dropped
    }

    nonisolated struct SpanOutcome: Sendable, Equatable {
        var spanID: Int
        var isAutoSkip: Bool
        var fate: SpanFate
        var mergedIntoZoneID: Int?
    }

    nonisolated struct Column: Sendable, Equatable {
        var basis: DurationBasis
        var autoSkipZones: [PlaybackSkipZone]
        var displayOnlyZones: [PlaybackSkipZone]
        var spanOutcomes: [SpanOutcome]
        /// nil when the episode isn't loaded in the player, so there is
        /// nothing installed to compare against.
        var matchesInstalledAutoSkipZones: Bool?
    }

    var columns: [Column]

    @MainActor
    static func make(
        document: EpisodeAdAnalysisDocument,
        bases: [DurationBasis],
        installedAutoSkipZones: [PlaybackSkipZone]?
    ) -> EpisodeDiagnosticsZoneMatrix {
        let columns = bases.map { basis in
            let tiers = EpisodeAdAnalysisZoneMapper.zoneTiers(for: document, duration: basis.duration)
            let outcomes = document.spans.map { span in
                spanOutcome(for: span, in: document, duration: basis.duration, tiers: tiers)
            }
            return Column(
                basis: basis,
                autoSkipZones: tiers.autoSkip,
                displayOnlyZones: tiers.displayOnly,
                spanOutcomes: outcomes,
                matchesInstalledAutoSkipZones: installedAutoSkipZones.map { $0 == tiers.autoSkip }
            )
        }
        return EpisodeDiagnosticsZoneMatrix(columns: columns)
    }

    @MainActor
    private static func spanOutcome(
        for span: EpisodeAdAnalysisSpan,
        in document: EpisodeAdAnalysisDocument,
        duration: TimeInterval?,
        tiers: EpisodeAdAnalysisZoneTiers
    ) -> SpanOutcome {
        var soloDocument = document
        soloDocument.spans = [span]
        let soloTiers = EpisodeAdAnalysisZoneMapper.zoneTiers(for: soloDocument, duration: duration)
        let isAutoSkip = span.confidence >= EpisodeAdAnalysisZoneMapper.autoSkipConfidenceFloor
        let soloZone = (isAutoSkip ? soloTiers.autoSkip : soloTiers.displayOnly).first

        guard let soloZone else {
            return SpanOutcome(spanID: span.id, isAutoSkip: isAutoSkip, fate: .dropped, mergedIntoZoneID: nil)
        }

        let fate: SpanFate = soloZone.startTime == span.startTime && soloZone.endTime == span.endTime
            ? .preserved
            : .clamped(startTime: soloZone.startTime, endTime: soloZone.endTime)

        // Merged runs keep the first span's zone ID, so a span whose ID is
        // absent from the full tier survived only inside another zone.
        let tierZones = isAutoSkip ? tiers.autoSkip : tiers.displayOnly
        var mergedIntoZoneID: Int?
        if !tierZones.contains(where: { $0.id == span.id }) {
            mergedIntoZoneID = tierZones.first {
                $0.startTime <= soloZone.startTime && soloZone.endTime <= $0.endTime
            }?.id
        }
        return SpanOutcome(
            spanID: span.id,
            isAutoSkip: isAutoSkip,
            fate: fate,
            mergedIntoZoneID: mergedIntoZoneID
        )
    }
}
