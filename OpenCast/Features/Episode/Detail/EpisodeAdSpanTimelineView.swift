import OpenCastPlayback
import SwiftUI

/// Full-width ad-span rail plus a human caption, shown once ad analysis has
/// completed for the episode.
struct EpisodeAdSpanTimelineView: View {
    static let outdatedCaption = "Ad analysis outdated — rerun from the menu"
    static let emptyCaption = "No ad segments detected"

    let duration: TimeInterval
    let zoneTiers: EpisodeAdAnalysisZoneTiers
    let isStale: Bool

    var body: some View {
        let summary = EpisodeAdSpanSummary.make(zoneTiers: zoneTiers)

        VStack(alignment: .leading, spacing: 8) {
            if summary != nil, duration > 0 {
                NowPlayingSkipZoneRail(
                    duration: duration,
                    zones: zoneTiers.autoSkip,
                    displayOnlyZones: zoneTiers.displayOnly
                )
                .opacity(isStale ? 0.35 : 1)
            }

            Text(caption(for: summary))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func caption(for summary: EpisodeAdSpanSummary?) -> String {
        if isStale {
            return Self.outdatedCaption
        }
        return summary?.caption ?? Self.emptyCaption
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
        isStale: false
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
        isStale: true
    )
    .padding()
    .preferredColorScheme(.light)
}
