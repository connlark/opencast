import Foundation
import OpenCastPlayback
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode ad-span summary")
struct EpisodeAdSpanSummaryTests {
    @Test("Empty tiers produce no summary")
    func emptyTiers() {
        #expect(EpisodeAdSpanSummary.make(zoneTiers: .empty) == nil)
    }

    @Test("Counts and total duration span both tiers")
    func countsBothTiers() throws {
        let tiers = EpisodeAdAnalysisZoneTiers(
            autoSkip: [PlaybackSkipZone(id: 1, startTime: 40, endTime: 65)],
            displayOnly: [
                PlaybackSkipZone(id: 2, startTime: 120, endTime: 180),
                PlaybackSkipZone(id: 3, startTime: 470, endTime: 520)
            ]
        )

        let summary = try #require(EpisodeAdSpanSummary.make(zoneTiers: tiers))
        #expect(summary.segmentCount == 3)
        #expect(summary.totalDuration == 135)
        #expect(summary.caption == "3 ad segments · 2m 15s")
    }

    @Test("A single span uses singular copy")
    func singularCaption() throws {
        let tiers = EpisodeAdAnalysisZoneTiers(
            autoSkip: [PlaybackSkipZone(id: 1, startTime: 0, endTime: 372)],
            displayOnly: []
        )

        let summary = try #require(EpisodeAdSpanSummary.make(zoneTiers: tiers))
        #expect(summary.caption == "1 ad segment · 6m 12s")
    }

    @Test("Duration formatting covers seconds, minutes, and hours")
    func durationFormatting() {
        #expect(caption(totalSeconds: 45) == "1 ad segment · 45s")
        #expect(caption(totalSeconds: 120) == "1 ad segment · 2m")
        #expect(caption(totalSeconds: 3_600) == "1 ad segment · 1h")
        #expect(caption(totalSeconds: 3_660) == "1 ad segment · 1h 1m")
    }

    @Test("Inverted spans clamp to zero instead of going negative")
    func invertedSpanClamps() throws {
        let tiers = EpisodeAdAnalysisZoneTiers(
            autoSkip: [PlaybackSkipZone(id: 1, startTime: 100, endTime: 40)],
            displayOnly: []
        )

        let summary = try #require(EpisodeAdSpanSummary.make(zoneTiers: tiers))
        #expect(summary.totalDuration == 0)
    }

    @Test("The timeline caption: an outdated analysis wins over a detached one, a detached one over the summary")
    func timelineCaptionPrecedence() throws {
        let summary = try #require(EpisodeAdSpanSummary.make(zoneTiers: EpisodeAdAnalysisZoneTiers(
            autoSkip: [PlaybackSkipZone(id: 1, startTime: 0, endTime: 45)],
            displayOnly: []
        )))
        typealias Timeline = EpisodeAdSpanTimelineView

        #expect(Timeline.caption(for: summary, isStale: true, isDetached: true) == Timeline.outdatedCaption)
        #expect(Timeline.caption(for: summary, isStale: true, isDetached: false) == Timeline.outdatedCaption)
        #expect(Timeline.caption(for: summary, isStale: false, isDetached: true) == Timeline.detachedCaption)
        #expect(Timeline.caption(for: summary, isStale: false, isDetached: false) == "1 ad segment · 45s")
        #expect(Timeline.caption(for: nil, isStale: false, isDetached: false) == Timeline.emptyCaption)
        #expect(Timeline.detachedCaption == "Ad skips unavailable for this audio. Detect Ads Again to restore them.")
    }

    @Test("A detached analysis that found no ad spans keeps the caption it has attached: it lost no skips")
    func detachedAnalysisWithoutSpansKeepsTheEmptyCaption() {
        typealias Timeline = EpisodeAdSpanTimelineView
        let summary = EpisodeAdSpanSummary.make(zoneTiers: .empty)

        #expect(Timeline.caption(for: summary, isStale: false, isDetached: true) == Timeline.emptyCaption)
        #expect(Timeline.caption(for: summary, isStale: true, isDetached: true) == Timeline.outdatedCaption)
    }

    private func caption(totalSeconds: TimeInterval) -> String? {
        let tiers = EpisodeAdAnalysisZoneTiers(
            autoSkip: [PlaybackSkipZone(id: 1, startTime: 0, endTime: totalSeconds)],
            displayOnly: []
        )
        return EpisodeAdSpanSummary.make(zoneTiers: tiers)?.caption
    }
}
