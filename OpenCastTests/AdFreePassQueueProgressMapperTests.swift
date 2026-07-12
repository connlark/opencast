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
            for: .analyzing,
            queueContext: AdFreePassQueueContext(finishedItemCount: 0, totalItemCount: 2, episodeTitle: "A")
        )
        #expect(mapper.markDrained() == 1_000)
        #expect(mapper.fractionCompleted == 1.0)
    }

    @Test("Reset clears composite state")
    func resetClearsState() {
        var mapper = AdFreePassQueueProgressMapper()
        _ = mapper.update(
            for: .analyzing,
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
            (.analyzing, 0),
            (.analyzing, 30),
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
