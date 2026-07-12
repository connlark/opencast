import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode transcript generation progress mapper")
struct EpisodeTranscriptGenerationProgressMapperTests {
    @Test("Phase flow maps to the settled unit bands")
    func phaseFlowMapsToSettledUnitBands() {
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .downloading) == 20)
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .downloading, stageElapsed: 1_000) == 140)
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .preparingWhisper) == 150)
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .preparingWhisper, installFraction: 0.5) == 200)
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .preparingWhisper, installFraction: 2) == 250)
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .transcribingWhisper) == 250)
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .transcribingWhisper, transcriptionFraction: 0.5) == 600)
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .transcribingAppleSpeech, transcriptionFraction: 0.5) == 600)
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .transcribingWhisper, transcriptionFraction: 1, stageElapsed: 1_000) == 975)
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .completed) == 1_000)
    }

    @Test("Terminal pauses hold the current units")
    func terminalPausesHoldCurrentUnits() {
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .interrupted, currentUnits: 600) == 600)
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .cancelled, currentUnits: 600) == 600)
        #expect(EpisodeTranscriptGenerationProgressMapper.units(for: .failed("probe"), currentUnits: 600) == 600)
    }

    @Test("Updates are monotonic across phase regressions")
    func updatesAreMonotonicAcrossPhaseRegressions() {
        var mapper = EpisodeTranscriptGenerationProgressMapper()

        #expect(mapper.update(for: .transcribingWhisper, transcriptionFraction: 0.5) == 600)
        #expect(mapper.update(for: .preparingWhisper, installFraction: 1) == 600)
        #expect(mapper.update(for: .transcribingWhisper, transcriptionFraction: 0.4) == 600)
        #expect(mapper.update(for: .transcribingWhisper, transcriptionFraction: 0.6) == 670)
        #expect(mapper.update(for: .completed) == 1_000)

        mapper.reset()
        #expect(mapper.completedUnitCount == 0)
    }

    @Test("Transcription creep advances through checkpoint droughts")
    func transcriptionCreepAdvancesThroughCheckpointDroughts() {
        var mapper = EpisodeTranscriptGenerationProgressMapper()

        let base = mapper.update(for: .transcribingWhisper, transcriptionFraction: 0.2)
        let crept = mapper.update(for: .transcribingWhisper, transcriptionFraction: 0.2, stageElapsed: 10)
        #expect(crept == base + 5)
    }
}
