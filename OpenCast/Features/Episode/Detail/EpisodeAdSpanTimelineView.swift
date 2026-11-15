import OpenCastPlayback
import SwiftUI

/// Full-width ad-span rail plus a human caption, shown once ad analysis has
/// completed for the episode.
struct EpisodeAdSpanTimelineView: View {
    static let outdatedCaption = "Ad analysis outdated — rerun from the menu"
    static let detachedCaption = "Ad skips unavailable for this audio. Detect Ads Again to restore them."
    static let emptyCaption = "No ad segments detected"

    let duration: TimeInterval
    let zoneTiers: EpisodeAdAnalysisZoneTiers
    let isStale: Bool
    /// The analysis no longer matches a completed download, so none of its
    /// spans can skip.
    let isDetached: Bool

    var body: some View {
        let summary = EpisodeAdSpanSummary.make(zoneTiers: zoneTiers)

        VStack(alignment: .leading, spacing: 8) {
            if summary != nil, duration > 0 {
                NowPlayingSkipZoneRail(
                    duration: duration,
                    zones: zoneTiers.autoSkip,
                    displayOnlyZones: zoneTiers.displayOnly
                )
                .opacity(isStale || isDetached ? 0.35 : 1)
            }

            Text(Self.caption(for: summary, isStale: isStale, isDetached: isDetached))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// A stale analysis has no spans to show, so it says so whether or not
    /// its download is still there. A detached one that found no spans lost
    /// no skips, so it keeps the empty caption.
    static func caption(for summary: EpisodeAdSpanSummary?, isStale: Bool, isDetached: Bool) -> String {
        if isStale {
            return outdatedCaption
        }
        guard let summary else {
            return emptyCaption
        }
        return isDetached ? detachedCaption : summary.caption
    }
}

#Preview("Dark") {
    EpisodeAdSpanTimelineView(
        duration: 600,
        zoneTiers: EpisodeAdAnalysisZoneTiers(
            autoSkip: [
                PlaybackSkipZone(id: 1, startTime: 40, endTime: 65),
                PlaybackSkipZone(id: 2, startTime: 310, endTime: 350)
            ],
            displayOnly: [PlaybackSkipZone(id: 3, startTime: 470, endTime: 520)]
        ),
        isStale: false,
        isDetached: false
    )
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    EpisodeAdSpanTimelineView(
        duration: 600,
        zoneTiers: EpisodeAdAnalysisZoneTiers(
            autoSkip: [PlaybackSkipZone(id: 1, startTime: 40, endTime: 65)],
            displayOnly: []
        ),
        isStale: true,
        isDetached: false
    )
    .padding()
    .preferredColorScheme(.light)
}

#Preview("Detached") {
    EpisodeAdSpanTimelineView(
        duration: 600,
        zoneTiers: EpisodeAdAnalysisZoneTiers(
            autoSkip: [PlaybackSkipZone(id: 1, startTime: 40, endTime: 65)],
            displayOnly: []
        ),
        isStale: false,
        isDetached: true
    )
    .padding()
    .preferredColorScheme(.dark)
}
