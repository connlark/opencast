import Testing
@testable import OpenCastVoiceBoost

struct VoiceBoostOptionalMeteringTests {
    @Test(arguments: [44_100.0, 48_000.0, 96_000.0], [1, 2])
    func omittingPeakReportPreservesAudioAndControlState(sampleRate: Double, channelCount: Int) {
        let metered = VoiceBoostProcessor(sampleRate: sampleRate, channelCount: channelCount)
        let unmetered = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            measuresOutputTruePeak: false
        )
        let speech = VoiceBoostFixtureGenerator.alternatingSpeechLike(
            quietAmplitude: 0.025,
            loudAmplitude: 1.3,
            segmentDuration: 0.4,
            sampleRate: sampleRate,
            duration: 3,
            channelCount: channelCount
        )
        let stress = VoiceBoostFixtureGenerator.sine(
            frequency: sampleRate / 4,
            amplitude: 1.2,
            sampleRate: sampleRate,
            duration: 0.2,
            channelCount: channelCount
        )
        let silence = VoiceBoostFixtureGenerator.silence(
            sampleRate: sampleRate,
            duration: 0.2,
            channelCount: channelCount
        )
        for (index, fixture) in [speech, stress, silence, speech, speech, speech].enumerated() {
            var configuration = VoiceBoostConfiguration.default
            configuration.isEnabled = index != 3
            metered.update(configuration: configuration)
            unmetered.update(configuration: configuration)
            if index == 5 {
                metered.reset()
                unmetered.reset()
            }
            var reportedAudio = fixture
            var playbackAudio = fixture
            // Irregular callbacks exercise FIR history and loudness boundaries.
            let blockSize = [1_024, 127, 4_096, 251, 512, 1_024][index]
            VoiceBoostFixtureGenerator.processInBlocks(
                &reportedAudio, processor: metered, channelCount: channelCount, blockSize: blockSize
            )
            VoiceBoostFixtureGenerator.processInBlocks(
                &playbackAudio, processor: unmetered, channelCount: channelCount, blockSize: blockSize
            )
            #expect(reportedAudio.withUnsafeBytes { reported in
                playbackAudio.withUnsafeBytes { reported.elementsEqual($0) }
            })
            #expect(metered.controlSnapshot.desiredGainDB == unmetered.controlSnapshot.desiredGainDB)
            #expect(metered.controlSnapshot.chainLossDB == unmetered.controlSnapshot.chainLossDB)
            #expect(metered.controlSnapshot.gatedBlockCount == unmetered.controlSnapshot.gatedBlockCount)
            #expect(unmetered.metrics.outputTruePeakDBTP == nil)
            var reportedMetrics = metered.metrics
            reportedMetrics.outputTruePeakDBTP = nil
            #expect(reportedMetrics == unmetered.metrics)
            #expect(unmetered.metrics.safetyClampCount == 0)
        }
    }
}
