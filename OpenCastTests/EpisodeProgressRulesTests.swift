import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode progress rules")
struct EpisodeProgressRulesTests {
    @Test("Played detection follows the remaining-time threshold")
    func playedDetectionFollowsRemainingTimeThreshold() {
        #expect(!EpisodeProgressRules.isPlayed(position: 500, duration: nil))
        #expect(!EpisodeProgressRules.isPlayed(position: 0, duration: 1_000))
        #expect(!EpisodeProgressRules.isPlayed(position: 500, duration: 0))

        // Long episode: fixed 60 s remaining threshold.
        #expect(EpisodeProgressRules.isPlayed(position: 941, duration: 1_000))
        #expect(!EpisodeProgressRules.isPlayed(position: 940, duration: 1_000))

        // Short episode: the threshold halves with duration.
        #expect(EpisodeProgressRules.isPlayed(position: 51, duration: 100))
        #expect(!EpisodeProgressRules.isPlayed(position: 50, duration: 100))

        // Positions past the end clamp instead of reading as unplayed.
        #expect(EpisodeProgressRules.isPlayed(position: 2_000, duration: 1_000))
    }

    @Test("Duration changes are meaningful only past the one-second epsilon")
    func durationChangesAreMeaningfulOnlyPastEpsilon() {
        #expect(!EpisodeProgressRules.hasMeaningfulDurationChange(nil, nil))
        #expect(EpisodeProgressRules.hasMeaningfulDurationChange(nil, 100))
        #expect(EpisodeProgressRules.hasMeaningfulDurationChange(100, nil))
        #expect(!EpisodeProgressRules.hasMeaningfulDurationChange(100, 100.9))
        #expect(EpisodeProgressRules.hasMeaningfulDurationChange(100, 101))
        #expect(EpisodeProgressRules.hasMeaningfulDurationChange(100, 99))
    }

    @Test("Non-finite durations compare by equality instead of epsilon")
    func nonFiniteDurationsCompareByEquality() {
        #expect(!EpisodeProgressRules.hasMeaningfulDurationChange(.infinity, .infinity))
        #expect(EpisodeProgressRules.hasMeaningfulDurationChange(.infinity, 100))
        #expect(EpisodeProgressRules.hasMeaningfulDurationChange(100, .infinity))
        // NaN never equals itself, so a NaN pair always reads as changed —
        // the write path then persists whatever the sanitizers hand it.
        #expect(EpisodeProgressRules.hasMeaningfulDurationChange(.nan, .nan))
    }

    @Test("Progress changes gate on played flips, duration, then position epsilon")
    func progressChangesGateOnPlayedDurationThenPosition() {
        let record = EpisodeProgressRecord(
            episodeID: "rules-episode",
            podcastID: "https://example.com/rules.xml",
            position: 100,
            duration: 600,
            isPlayed: false
        )

        #expect(EpisodeProgressRules.hasMeaningfulProgressChange(
            record, position: 100, duration: 600, isPlayed: true
        ))
        #expect(EpisodeProgressRules.hasMeaningfulProgressChange(
            record, position: 100, duration: 700, isPlayed: false
        ))
        #expect(EpisodeProgressRules.hasMeaningfulProgressChange(
            record, position: 101, duration: 600, isPlayed: false
        ))
        #expect(EpisodeProgressRules.hasMeaningfulProgressChange(
            record, position: 99, duration: 600, isPlayed: false
        ))
        #expect(!EpisodeProgressRules.hasMeaningfulProgressChange(
            record, position: 100.9, duration: 600, isPlayed: false
        ))
        #expect(!EpisodeProgressRules.hasMeaningfulProgressChange(
            record, position: 100, duration: 600.5, isPlayed: false
        ))
    }
}
