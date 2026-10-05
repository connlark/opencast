import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode remote transcription progress mapper")
struct EpisodeRemoteTranscriptionProgressMapperTests {
    private typealias Mapper = EpisodeRemoteTranscriptionProgressMapper

    @Test("Phases map onto strictly ascending bands that only completion fills")
    func phasesMapOntoAscendingBands() {
        let ordered: [RemoteTranscriptionRequestPhase] = [
            .preparing,
            .downloadingBoth,
            .verifying,
            .uploadingExactCopy(completedParts: 0, totalParts: 4),
            .waitingForCredits,
            .processing(Self.progress(.checkingAudioDetails)),
            .processing(Self.progress(.transcribing, fraction: 0)),
            .processing(Self.progress(.finalizing)),
            .saving,
            .completed,
        ]
        let units = ordered.map { Mapper.units(for: $0) }

        #expect(units[0] > 0)
        #expect(zip(units, units.dropFirst()).allSatisfy { $0 < $1 })
        #expect(units.last == Mapper.totalUnitCount)
        #expect(units.dropLast().allSatisfy { $0 < Mapper.totalUnitCount })
    }

    @Test("Uploaded parts and server chunks move progress inside their own bands")
    func fractionsMoveInsideBands() {
        let upload = [0, 2, 4].map {
            Mapper.units(for: .uploadingExactCopy(completedParts: $0, totalParts: 4))
        }
        #expect(upload[0] < upload[1] && upload[1] < upload[2])
        #expect(upload[2] <= Mapper.units(for: .waitingForCredits))

        let transcribing = [0.0, 0.5, 1.0].map {
            Mapper.units(for: .processing(Self.progress(.transcribing, fraction: $0)))
        }
        #expect(transcribing[0] < transcribing[1] && transcribing[1] < transcribing[2])
        #expect(transcribing[2] <= Mapper.units(for: .processing(Self.progress(.finalizing))))
    }

    @Test("Creep advances a long phase but never past the next band")
    func creepIsCappedBelowTheNextBand() {
        let start = Mapper.units(for: .downloadingBoth)
        let later = Mapper.units(for: .downloadingBoth, stageElapsed: 20)
        let stalled = Mapper.units(for: .downloadingBoth, stageElapsed: 100_000)
        #expect(start < later)
        #expect(stalled <= Mapper.units(for: .verifying))

        let processingStalled = Mapper.units(
            for: .processing(Self.progress(.transcribing, fraction: 1)),
            stageElapsed: 100_000
        )
        #expect(processingStalled <= Mapper.units(for: .processing(Self.progress(.finalizing))))
        #expect(Mapper.units(for: .saving, stageElapsed: 100_000) < Mapper.totalUnitCount)
    }

    @Test("Progress never moves backward through phase regressions, ETA re-projection, duplicates, a park or a failure")
    func progressIsMonotonic() {
        var mapper = Mapper()
        let verified = mapper.update(for: .verifying)
        #expect(verified > 0)
        // A poll reporting the job queued again maps back to the download phase.
        #expect(mapper.update(for: .downloadingBoth) == verified)

        let halfway = mapper.update(for: .processing(Self.progress(
            .transcribing,
            fraction: 0.5,
            estimate: .onTrack(remainingSeconds: 60)
        )))
        #expect(halfway > verified)
        // A longer re-projected ETA or a lower reported fraction holds.
        #expect(mapper.update(for: .processing(Self.progress(.transcribing, fraction: 0.4, estimate: .delayed))) == halfway)
        #expect(mapper.update(for: .processing(Self.progress(
            .transcribing,
            fraction: 0.5,
            estimate: .onTrack(remainingSeconds: 900)
        ))) == halfway)
        #expect(mapper.update(for: .processing(Self.progress(.checkingAudioDetails))) == halfway)
        #expect(mapper.update(for: .parkedOnServer(.parked)) == halfway)
        #expect(mapper.update(for: .failed(.localRequestFailed)) == halfway)
        #expect(mapper.completedUnitCount == halfway)

        mapper.reset()
        #expect(mapper.completedUnitCount == 0)
    }

    @Test("Parked and unsuccessful phases hold the current units; completion fills the card")
    func parkedAndTerminalPhasesHold() {
        let held: [RemoteTranscriptionRequestPhase] = [
            .parkedOnServer(.parked),
            .parkedOnServer(.connectionLost),
            .failed(.serviceUnavailable),
            .cancelled,
            .mismatchLocalFallback,
        ]
        for phase in held {
            #expect(Mapper.units(for: phase, currentUnits: 432) == 432)
        }
        #expect(Mapper.units(for: .completed, currentUnits: 432) == Mapper.totalUnitCount)
    }

    private static func progress(
        _ stage: RemoteTranscriptionActiveStage,
        fraction: Double? = nil,
        estimate: RemoteTranscriptionEstimate? = nil
    ) -> RemoteTranscriptionActiveProgress {
        RemoteTranscriptionActiveProgress(
            stage: stage,
            completedChunks: nil,
            totalChunks: nil,
            fractionCompleted: fraction,
            estimate: estimate
        )
    }
}
