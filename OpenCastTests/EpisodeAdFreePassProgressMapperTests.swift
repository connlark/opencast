import Foundation
import OpenCastAnalysis
import OpenCastTranscription
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode ad-free pass progress mapper")
struct EpisodeAdFreePassProgressMapperTests {
    @Test("Maps planned stage boundaries into task progress units")
    func mapsStageBoundaries() {
        #expect(EpisodeAdFreePassProgressMapper.units(for: .idle) == 0)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .downloadingEpisode) == 20)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .downloadingEpisode, stageElapsed: 240) == 140)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .installingModel(installProgress(0.5))) == 200)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .installingModel(installProgress(1))) == 250)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .transcribing(transcriptionProgress(0.5))) == 575)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .transcribing(transcriptionProgress(1))) == 900)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .analyzing(steps: nil)) == 910)
        // Before the run knows its steps it creeps as one window and the
        // step to come (910 to 942) over the baked step budget, 250 s.
        #expect(AdAnalysisRunProgress.defaultStepBudgetSeconds == 250)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .analyzing(steps: nil), stageElapsed: 125) == 925)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .analyzing(steps: nil), stageElapsed: 1_000) == 941)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .completed(zoneCount: 3)) == 1_000)
    }

    @Test("Transcription creeps through checkpoint droughts without leaving the stage band")
    func transcribingCreepsDuringCheckpointDroughts() {
        // 60 s without a real checkpoint still moves units (the system
        // expires tasks whose progress looks dead for ~a minute).
        #expect(EpisodeAdFreePassProgressMapper.units(
            for: .transcribing(transcriptionProgress(0.5)),
            stageElapsed: 60
        ) == 605)
        // The creep can never leapfrog the analyzing band.
        #expect(EpisodeAdFreePassProgressMapper.units(
            for: .transcribing(transcriptionProgress(0.9)),
            stageElapsed: 3_600
        ) == 900)
    }

    @Test("Never moves backwards when a resumed pass re-enters an earlier stage")
    func clampsMonotonically() {
        var mapper = EpisodeAdFreePassProgressMapper()

        #expect(mapper.update(for: .transcribing(transcriptionProgress(0.75))) == 737)
        #expect(mapper.update(for: .installingModel(installProgress(1))) == 737)
        #expect(mapper.update(for: .interrupted) == 737)
        #expect(mapper.update(for: .analyzing(steps: nil)) == 910)
    }

    @Test("Analyzing maps the run's steps into equal slices whose creep is paced over the step budget, one unit short of each slice end")
    func analyzingStepsMapIntoPacedSlices() {
        // 910 + 65 × completed/total opens each slice.
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(0, of: 5)) == 910)
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(2, of: 5)) == 936)
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(4, of: 5)) == 962)
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(1, of: 2)) == 942)
        // Inside a slice the creep covers its room (slice end − 1 − start)
        // in proportion to the step budget's elapsed share (100 s here).
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(0, of: 5), stageElapsed: 50) == 916)
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(2, of: 5), stageElapsed: 25) == 939)
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(1, of: 2), stageElapsed: 50) == 958)
        // At and past the budget it stops one unit short of its slice end.
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(0, of: 5), stageElapsed: 100) == 922)
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(2, of: 5), stageElapsed: 1_000) == 948)
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(4, of: 5), stageElapsed: 1_000) == 974)
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(1, of: 2), stageElapsed: 1_000) == 974)
        // Every step answered: the band's end, with no creep past it.
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(5, of: 5)) == 975)
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(5, of: 5), stageElapsed: 1_000) == 975)
        // More steps than units: a slice narrower than one unit holds its start.
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(0, of: 200), stageElapsed: 1_000) == 910)
        #expect(EpisodeAdFreePassProgressMapper.units(for: analyzing(100, of: 200)) == 942)
    }

    @Test("A long single step keeps moving across its whole budget and never reaches its slice end")
    func longSingleStepKeepsMovingAcrossItsBudget() {
        // One window and the step to come: slice 910 to 942, budget 250 s.
        let stage = analyzing(0, of: 2, budget: 250)
        let elapsed: [TimeInterval] = [0, 30, 60, 70, 120, 180, 240, 250]
        let units = elapsed.map { EpisodeAdFreePassProgressMapper.units(for: stage, stageElapsed: $0) }
        #expect(units == [910, 913, 917, 918, 924, 932, 939, 941])
        // Strictly rising across the budget: a 2 s-per-unit creep would
        // have spent the slice by 62 s.
        #expect(zip(units, units.dropFirst()).allSatisfy { $0 < $1 })
        #expect(EpisodeAdFreePassProgressMapper.units(for: stage, stageElapsed: 3_600) == 941)
    }

    @Test("A window whose answer fails validation keeps a slow repair below the band's end until the run ends")
    func slowRepairAfterAnInvalidAnswerNeverParksAtTheCeiling() throws {
        var model = try #require(AnalysisPolicySnapshot.baked.adDetection(provider: .google)).model
        model.perCallTimeoutSeconds = 60
        var progress = AdAnalysisRunProgress(windowCount: 1, model: model)
        // Two 60 s sends and the pause between them.
        #expect(progress.stepBudgetSeconds == 130)
        var mapper = EpisodeAdFreePassProgressMapper()
        #expect(mapper.update(for: .analyzing(steps: EpisodeAdFreePassAnalysisSteps(progress))) == 910)

        // The reply comes back and fails validation: its send still counts
        // the window answered, and the repair is not known until it ends.
        progress.note(.adWindow(index: 0), answered: true)
        #expect(progress.completed == progress.total)
        let repairing = EpisodeAdFreePassStage.analyzing(steps: EpisodeAdFreePassAnalysisSteps(progress))
        #expect(repairing == .analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 1, total: 2, stepBudgetSeconds: 130)))
        #expect(mapper.update(for: repairing) == 942)

        // The held repair: every 10 s of its budget moves the units, never
        // to the band's end.
        var previous = mapper.completedUnitCount
        for elapsed in stride(from: 10.0, through: 130, by: 10) {
            let units = mapper.update(for: repairing, stageElapsed: elapsed)
            #expect(units > previous, "elapsed \(elapsed)")
            #expect(units < 975, "elapsed \(elapsed)")
            previous = units
        }
        #expect(mapper.update(for: repairing, stageElapsed: 3_600) == 974)

        // The repair answers: a corrective step joins, the units hold, and
        // only the run's end reaches 1000.
        progress.note(.adRepair(index: 0), answered: true)
        #expect(EpisodeAdFreePassAnalysisSteps(progress) == EpisodeAdFreePassAnalysisSteps(completed: 2, total: 3, stepBudgetSeconds: 130))
        #expect(mapper.update(for: .analyzing(steps: EpisodeAdFreePassAnalysisSteps(progress))) == 974)
        #expect(mapper.update(for: .completed(zoneCount: 0)) == 1_000)
    }

    @Test("A long run moves with each answered step and never goes back when a corrective step joins")
    func analyzingRunMovesStepByStepWithoutGoingBack() {
        var mapper = EpisodeAdFreePassProgressMapper()

        #expect(mapper.update(for: analyzing(0, of: 4)) == 910)
        // A slow first step parks one unit short of its slice end (926).
        #expect(mapper.update(for: analyzing(0, of: 4), stageElapsed: 600) == 925)
        #expect(mapper.update(for: analyzing(1, of: 4)) == 926)
        // A corrective request widens the total: the slice start drops to
        // 923, and the mapper holds until the paced creep passes it.
        #expect(mapper.update(for: analyzing(1, of: 5)) == 926)
        #expect(mapper.update(for: analyzing(1, of: 5), stageElapsed: 20) == 926)
        #expect(mapper.update(for: analyzing(1, of: 5), stageElapsed: 50) == 929)
        #expect(mapper.update(for: analyzing(2, of: 5)) == 936)
        #expect(mapper.update(for: analyzing(2, of: 5), stageElapsed: 600) == 948)
        #expect(mapper.update(for: analyzing(5, of: 5)) == 975)
        #expect(mapper.update(for: .completed(zoneCount: 1)) == 1_000)
    }

    @Test("Terminal failure-style stages hold the current unit count")
    func terminalFailuresHoldCurrentUnits() {
        #expect(EpisodeAdFreePassProgressMapper.units(
            for: .awaitingModelDownloadConsent(byteCount: 75_000_000),
            currentUnits: 150
        ) == 150)
        #expect(EpisodeAdFreePassProgressMapper.units(
            for: .failed(message: "Nope"),
            currentUnits: 500
        ) == 500)
        #expect(EpisodeAdFreePassProgressMapper.units(
            for: .unavailable("Unavailable"),
            currentUnits: 600
        ) == 600)
        #expect(EpisodeAdFreePassProgressMapper.units(
            for: .interrupted,
            currentUnits: 700
        ) == 700)
    }

    private func analyzing(_ completed: Int, of total: Int, budget: Double = 100) -> EpisodeAdFreePassStage {
        .analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: completed, total: total, stepBudgetSeconds: budget))
    }

    private func installProgress(_ fraction: Double) -> OpenCastWhisperModelInstallProgress {
        let totalByteCount: Int64 = 1_000
        return OpenCastWhisperModelInstallProgress(
            modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
            version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
            completedFileCount: Int(fraction * 10),
            totalFileCount: 10,
            completedByteCount: Int64(fraction * Double(totalByteCount)),
            totalByteCount: totalByteCount,
            currentFilePath: nil
        )
    }

    private func transcriptionProgress(_ fraction: Double) -> EpisodeTranscriptionProgress {
        EpisodeTranscriptionProgress(
            audioDuration: 1_000,
            completedDuration: 1_000 * fraction,
            checkpointCount: 1,
            currentWindowIndex: nil,
            currentText: nil
        )
    }
}
