import Foundation
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
        #expect(EpisodeAdFreePassProgressMapper.units(for: .analyzing) == 910)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .analyzing, stageElapsed: 200) == 975)
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
        #expect(mapper.update(for: .analyzing) == 910)
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
