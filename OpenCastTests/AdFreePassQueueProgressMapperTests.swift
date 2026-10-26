import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad-free pass queue progress mapper")
struct AdFreePassQueueProgressMapperTests {
    @Test("A queue of one maps exactly like the per-episode mapper")
    func singleItemQueueMatchesPerEpisodeMapperExactly() {
        var queueMapper = AdFreePassQueueProgressMapper()
        var episodeMapper = EpisodeAdFreePassProgressMapper()
        let context = AdFreePassQueueContext(finishedItemCount: 0, totalItemCount: 1, episodeTitle: "Solo")

        for (stage, elapsed) in Self.singleItemStageTable {
            let queueUnits = queueMapper.update(for: stage, queueContext: context, stageElapsed: elapsed)
            let episodeUnits = episodeMapper.update(for: stage, stageElapsed: elapsed)
            #expect(queueUnits == episodeUnits, "stage \(stage)")
        }
        #expect(queueMapper.completedUnitCount == 1_000)
    }

    @Test("Composite units combine finished items with the current episode fraction")
    func compositeUnitsCombineFinishedAndCurrent() {
        var mapper = AdFreePassQueueProgressMapper()
        let units = mapper.update(
            for: .transcribing(Self.transcriptionProgress(0.5)),
            queueContext: AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 2, episodeTitle: "B")
        )
        // Per-episode: 250 + 325 = 575; composite: (1000 + 575) / 2 = 787.
        #expect(units == 787)
    }

    @Test("The queue moves with each answered analysis step of its current item")
    func compositeMovesWithAnalysisSteps() {
        var mapper = AdFreePassQueueProgressMapper()
        let context = AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 2, episodeTitle: "B")
        // Per-episode 910 + 65 × 1/4 = 926; composite (1000 + 926) / 2 = 963.
        #expect(mapper.update(
            for: .analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 1, total: 4)),
            queueContext: context
        ) == 963)
        // 910 + 65 × 3/4 = 958; (1000 + 958) / 2 = 979.
        #expect(mapper.update(
            for: .analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 3, total: 4)),
            queueContext: context
        ) == 979)
    }

    @Test("On a fine scale each creep tick of a long step moves the queue, never past one unit short of the step's end")
    func fineScaleTicksMoveAcrossALongStep() {
        let subunits: Int64 = 1_000_000
        var mapper = AdFreePassQueueProgressMapper(subunitsPerUnit: subunits)
        #expect(mapper.totalUnitCount == 1_000 * subunits)
        let context = AdFreePassQueueContext(finishedItemCount: 2, totalItemCount: 5, episodeTitle: "C")
        let stage = EpisodeAdFreePassStage.analyzing(
            steps: EpisodeAdFreePassAnalysisSteps(completed: 10, total: 41, stepBudgetSeconds: 250)
        )
        // The band edges are the 0...1000 points times the scale.
        let start = mapper.update(for: stage, queueContext: context)
        #expect(start == (2 * 1_000 * subunits + 910 * subunits + 65 * subunits * 10 / 41) / 5)
        let ceiling = (2 * 1_000 * subunits + 910 * subunits + 65 * subunits * 11 / 41 - 1) / 5

        // Every 2 s tick across the 250 s budget moves it.
        var previous = start
        for tick in 1...125 {
            let units = mapper.tick(for: stage, queueContext: context, stageElapsed: Double(tick * 2))
            #expect(units > previous, "tick \(tick)")
            #expect(units <= ceiling, "tick \(tick)")
            previous = units
        }
        // A tick whose clock has not moved still moves it; past the budget
        // it stops one unit short of the step's end, and never goes back.
        #expect(mapper.tick(for: stage, queueContext: context, stageElapsed: 250) == ceiling)
        #expect(mapper.tick(for: stage, queueContext: context, stageElapsed: 10_000) == ceiling)
        #expect(mapper.update(for: stage, queueContext: context, stageElapsed: 0) == ceiling)

        var stalled = AdFreePassQueueProgressMapper(subunitsPerUnit: subunits)
        let opened = stalled.update(for: stage, queueContext: context)
        #expect(stalled.tick(for: stage, queueContext: context, stageElapsed: 0) == opened + 1)

        // Other stages tick like updates.
        var holding = AdFreePassQueueProgressMapper(subunitsPerUnit: subunits)
        let held = holding.update(for: .interrupted, queueContext: context)
        #expect(holding.tick(for: .interrupted, queueContext: context, stageElapsed: 60) == held)
    }

    @Test("The fine scale maps every other stage onto its 0...1000 point times the scale")
    func fineScaleMapsBandEdges() {
        let subunits: Int64 = 1_000_000
        var fine = AdFreePassQueueProgressMapper(subunitsPerUnit: subunits)
        var coarse = AdFreePassQueueProgressMapper()
        let context = AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 2, episodeTitle: "B")
        for stage: EpisodeAdFreePassStage in [
            .downloadingEpisode, .transcribing(Self.transcriptionProgress(0.5)), .cloudFinishing, .completed(zoneCount: 1),
        ] {
            let coarseUnits = coarse.update(for: stage, queueContext: context, stageElapsed: 10)
            let fineUnits = fine.update(for: stage, queueContext: context, stageElapsed: 10)
            #expect(fineUnits / subunits == coarseUnits, "stage \(stage)")
        }
        #expect(fine.markDrained() == 1_000 * subunits)
        #expect(fine.fractionCompleted == 1)
    }

    @Test("Appending items mid-run holds the composite flat until real progress catches up")
    func appendingHoldsCompositeFlat() {
        var mapper = AdFreePassQueueProgressMapper()
        let before = mapper.update(
            for: .transcribing(Self.transcriptionProgress(0.75)),
            queueContext: AdFreePassQueueContext(finishedItemCount: 0, totalItemCount: 2, episodeTitle: "A")
        )
        #expect(before == 368)

        let afterAppend = mapper.update(
            for: .transcribing(Self.transcriptionProgress(0.9)),
            queueContext: AdFreePassQueueContext(finishedItemCount: 0, totalItemCount: 4, episodeTitle: "A")
        )
        #expect(afterAppend == 368)

        let afterFinishes = mapper.update(
            for: .downloadingEpisode,
            queueContext: AdFreePassQueueContext(finishedItemCount: 2, totalItemCount: 4, episodeTitle: "C")
        )
        #expect(afterFinishes == 505)
    }

    @Test("The per-episode mapper resets between items so later stages never inherit earlier units")
    func perEpisodeMapperResetsBetweenItems() {
        var mapper = AdFreePassQueueProgressMapper()
        _ = mapper.update(
            for: .completed(zoneCount: 2),
            queueContext: AdFreePassQueueContext(finishedItemCount: 0, totalItemCount: 2, episodeTitle: "A")
        )
        let secondItemStart = mapper.update(
            for: .downloadingEpisode,
            queueContext: AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 2, episodeTitle: "B")
        )
        // (1000 + 20) / 2 = 510 — the second item's download maps from a
        // fresh per-episode mapper, not the completed 1000.
        #expect(secondItemStart == 510)
    }

    @Test("markDrained pins the composite to the total unit count")
    func markDrainedPinsToTotal() {
        var mapper = AdFreePassQueueProgressMapper()
        _ = mapper.update(
            for: .analyzing(steps: nil),
            queueContext: AdFreePassQueueContext(finishedItemCount: 0, totalItemCount: 2, episodeTitle: "A")
        )
        #expect(mapper.markDrained() == 1_000)
        #expect(mapper.fractionCompleted == 1.0)
    }

    @Test("Reset clears composite state")
    func resetClearsState() {
        var mapper = AdFreePassQueueProgressMapper()
        _ = mapper.update(
            for: .analyzing(steps: nil),
            queueContext: AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 2, episodeTitle: "A")
        )
        mapper.reset()
        #expect(mapper.completedUnitCount == 0)
    }

    private static var singleItemStageTable: [(EpisodeAdFreePassStage, TimeInterval)] {
        [
            (.idle, 0),
            (.downloadingEpisode, 0),
            (.downloadingEpisode, 10),
            (.awaitingModelDownloadConsent(byteCount: 1_000), 0),
            (.installingSpeechAssets(fractionCompleted: 0.4), 0),
            (.transcribing(transcriptionProgress(0.25)), 0),
            (.transcribing(transcriptionProgress(0.8)), 0),
            (.analyzing(steps: nil), 0),
            (.analyzing(steps: nil), 30),
            (.analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 1, total: 4)), 0),
            (.analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 3, total: 4)), 30),
            (.completed(zoneCount: 3), 0)
        ]
    }

    private static func transcriptionProgress(_ fraction: Double) -> EpisodeTranscriptionProgress {
        EpisodeTranscriptionProgress(
            audioDuration: 1_000,
            completedDuration: 1_000 * fraction,
            checkpointCount: 1,
            currentWindowIndex: nil,
            currentText: nil
        )
    }
}
