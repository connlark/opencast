import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad-free pass queue progress mapper")
struct AdFreePassQueueProgressMapperTests {
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

    @Test("After creep moved a multi-item queue past its episode mapper, a slow handover keeps advancing on every tick")
    func slowHandoverKeepsAdvancingAfterCreep() {
        let subunits: Int64 = 1_000
        var mapper = AdFreePassQueueProgressMapper(subunitsPerUnit: subunits)
        let context = AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 3, episodeTitle: "B")
        // Four of five direct windows done, and the fifth still out.
        let direct = EpisodeAdFreePassStage.analyzing(
            steps: EpisodeAdFreePassAnalysisSteps(completed: 4, total: 6, stepBudgetSeconds: 250, attemptID: "direct")
        )
        func handover(_ completed: Int) -> EpisodeAdFreePassStage {
            .analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: completed, total: 11, stepBudgetSeconds: 250, attemptID: "handover"))
        }
        let stepPosition = mapper.update(for: direct, queueContext: context)

        // How far each could go: the direct step's own ceiling, and the first
        // handover step's, were that step based on the step position alone.
        var toDirectCeiling = mapper
        let directCeiling = toDirectCeiling.tick(for: direct, queueContext: context, stageElapsed: 250)
        var fromStepPosition = mapper
        _ = fromStepPosition.update(for: handover(0), queueContext: context)
        let ceilingFromStepPosition = fromStepPosition.tick(for: handover(0), queueContext: context, stageElapsed: 250)

        // Elapsed time holds, so the episode mapper stays on the step while
        // this mapper creeps on its own.
        var previous = stepPosition
        for _ in 1...1_000 {
            previous = mapper.tick(for: direct, queueContext: context, stageElapsed: 0)
        }
        #expect(previous == stepPosition + 1_000)
        #expect(previous < directCeiling)
        #expect(previous > ceilingFromStepPosition)

        // A fresh ten windows: every step of the handover moves on every tick,
        // from the first tick on.
        for completed in 0...4 {
            for tick in 1...125 {
                let units = mapper.tick(for: handover(completed), queueContext: context, stageElapsed: Double(tick * 2))
                #expect(units > previous, "step \(completed), tick \(tick)")
                previous = units
            }
        }
        // Still inside the item's own share of the queue.
        #expect(previous < 2 * 1_000 * subunits / 3)
    }

    @Test("The UI's mapper, updated without elapsed time, moves with a handover's steps from its own lower position")
    func uiMapperMovesWithTheHandoverSteps() {
        var mapper = AdFreePassQueueProgressMapper()
        let context = AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 3, episodeTitle: "B")
        let shown = mapper.update(
            for: .analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 4, total: 6, attemptID: "direct")),
            queueContext: context
        )
        let start = mapper.update(
            for: .analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 0, total: 11, attemptID: "handover")),
            queueContext: context
        )
        let later = mapper.update(
            for: .analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 8, total: 11, attemptID: "handover")),
            queueContext: context
        )

        #expect(start == shown)
        #expect(later > shown)
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
