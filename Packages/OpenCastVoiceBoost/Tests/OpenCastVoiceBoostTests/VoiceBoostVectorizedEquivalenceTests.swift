import Foundation
import Testing
@testable import OpenCastVoiceBoost

/// Pass 5: the vectorized planar engine against the retained scalar
/// reference (the oracle), and the interleaved wrapper against the planar
/// entry point. The oracle is the pre-vectorization implementation compiled
/// permanently behind `setScalarReferenceProcessing(true)`.
///
/// Null bounds and their provenance:
/// - limiterOnly below the ceiling is bit-identical by construction (unity
///   gains multiply bit-exactly and delay rings store byte copies).
/// - Configurations without compression are bounded by float32 drift in the
///   EQ cascade and auto-gain multiply (<= 1e-5 on +/-1-scale samples).
/// - Configurations with compression additionally carry the sanctioned
///   control-rate gain quantization (32-frame ticks, linearly interpolated,
///   <= 0.7 ms against 10/250 ms ballistics); the measured end-to-end bound
///   is recorded per test below.
struct VoiceBoostVectorizedEquivalenceTests {
    private func processedPair(
        fixture: [Float],
        sampleRate: Double,
        channelCount: Int,
        configuration: VoiceBoostConfiguration,
        blockSize: Int = 1_024
    ) -> (oracle: [Float], vectorized: [Float], oracleProcessor: VoiceBoostProcessor, vectorizedProcessor: VoiceBoostProcessor) {
        let oracleProcessor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: configuration
        )
        oracleProcessor.setScalarReferenceProcessing(true)
        let vectorizedProcessor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: configuration
        )

        var oracleBuffer = fixture
        var vectorizedBuffer = fixture
        VoiceBoostFixtureGenerator.processInBlocks(
            &oracleBuffer,
            processor: oracleProcessor,
            channelCount: channelCount,
            blockSize: blockSize
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &vectorizedBuffer,
            processor: vectorizedProcessor,
            channelCount: channelCount,
            blockSize: blockSize
        )
        return (oracleBuffer, vectorizedBuffer, oracleProcessor, vectorizedProcessor)
    }

    @Test
    func interleavedWrapperMatchesPlanarEntryBitExactly() {
        let sampleRate = 48_000.0
        let interleaved = VoiceBoostFixtureGenerator.alternatingSpeechLike(
            quietAmplitude: 0.05,
            loudAmplitude: 0.6,
            segmentDuration: 0.5,
            sampleRate: sampleRate,
            duration: 4,
            channelCount: 2
        )
        let frames = interleaved.count / 2

        var viaWrapper = interleaved
        let wrapperProcessor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 2,
            configuration: VoiceBoostPreset.default.configuration
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &viaWrapper,
            processor: wrapperProcessor,
            channelCount: 2
        )

        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            left[frame] = interleaved[frame * 2]
            right[frame] = interleaved[frame * 2 + 1]
        }
        let planarProcessor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 2,
            configuration: VoiceBoostPreset.default.configuration
        )
        left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                var offset = 0
                while offset < frames {
                    let blockFrames = min(1_024, frames - offset)
                    var pointers: [UnsafeMutablePointer<Float>?] = [
                        leftPointer.baseAddress! + offset,
                        rightPointer.baseAddress! + offset,
                    ]
                    pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                        planarProcessor.processPlanarFloat32(
                            pointerBuffer.baseAddress!,
                            frameCount: blockFrames
                        )
                    }
                    offset += blockFrames
                }
            }
        }

        var viaPlanar = [Float](repeating: 0, count: interleaved.count)
        for frame in 0..<frames {
            viaPlanar[frame * 2] = left[frame]
            viaPlanar[frame * 2 + 1] = right[frame]
        }

        #expect(VoiceBoostFixtureGenerator.maximumDelta(viaWrapper, viaPlanar) == 0)
    }

    @Test
    func limiterOnlyBelowCeilingMatchesOracleBitExactly() {
        let sampleRate = 48_000.0
        let fixture = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.3,
            sampleRate: sampleRate,
            duration: 4,
            channelCount: 2
        )
        let pair = processedPair(
            fixture: fixture,
            sampleRate: sampleRate,
            channelCount: 2,
            configuration: VoiceBoostPreset.limiterOnly.configuration
        )
        #expect(VoiceBoostFixtureGenerator.maximumDelta(pair.oracle, pair.vectorized) == 0)
    }

    @Test
    func limiterOnlyHotContentMatchesOracleClosely() {
        let sampleRate = 48_000.0
        let fixture = VoiceBoostFixtureGenerator.alternatingSpeechLike(
            quietAmplitude: 0.2,
            loudAmplitude: 1.3,
            segmentDuration: 0.4,
            sampleRate: sampleRate,
            duration: 4,
            channelCount: 2
        )
        let pair = processedPair(
            fixture: fixture,
            sampleRate: sampleRate,
            channelCount: 2,
            configuration: VoiceBoostPreset.limiterOnly.configuration
        )
        let delta = VoiceBoostFixtureGenerator.maximumDelta(pair.oracle, pair.vectorized)
        #expect(delta <= 1e-4, "hot limiterOnly null \(delta)")
        #expect(pair.vectorizedProcessor.metrics.safetyClampCount == 0)
        #expect(pair.oracleProcessor.metrics.safetyClampCount == 0)
    }

    /// Pure signal-path null: adaptive gain off pins the control loop, so
    /// the only differences are the vectorized stages themselves.
    @Test(arguments: [1, 2])
    func fixedGainEqualizedChainMatchesOracle(channelCount: Int) {
        let sampleRate = 48_000.0
        var configuration = VoiceBoostConfiguration.default
        configuration.usesCompression = false
        configuration.usesAdaptiveGain = false
        let fixture = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.4,
            sampleRate: sampleRate,
            duration: 4,
            channelCount: channelCount
        )
        let pair = processedPair(
            fixture: fixture,
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: configuration
        )
        let delta = VoiceBoostFixtureGenerator.maximumDelta(pair.oracle, pair.vectorized)
        #expect(delta <= 1e-5, "fixed-gain EQ null \(delta)")
    }

    /// With the control loop live, last-bit metering drift can shift *when*
    /// a deadband-gated gain step fires by one 100 ms hop; the engines then
    /// track the same trajectory offset by a hop for ~a slew step. The
    /// bound covers that transient timing skew, not signal-path precision
    /// (see fixedGainEqualizedChainMatchesOracle for the tight bound).
    @Test(arguments: [1, 2])
    func noCompressionChainMatchesOracle(channelCount: Int) {
        let sampleRate = 48_000.0
        var configuration = VoiceBoostConfiguration.default
        configuration.usesCompression = false
        let fixture = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.15,
            sampleRate: sampleRate,
            duration: 4,
            channelCount: channelCount
        )
        let pair = processedPair(
            fixture: fixture,
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: configuration
        )
        let delta = VoiceBoostFixtureGenerator.maximumDelta(pair.oracle, pair.vectorized)
        #expect(delta <= 2e-3, "no-compression null \(delta)")
        #expect(
            abs(pair.oracleProcessor.metrics.currentAutoGainDB - pair.vectorizedProcessor.metrics.currentAutoGainDB) <= 1e-3
        )
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func defaultChainMatchesOracleWithinTickQuantization(sampleRate: Double) {
        let fixture = VoiceBoostFixtureGenerator.alternatingSpeechLike(
            quietAmplitude: 0.04,
            loudAmplitude: 0.45,
            segmentDuration: 0.5,
            sampleRate: sampleRate,
            duration: 6,
            channelCount: 2
        )
        let pair = processedPair(
            fixture: fixture,
            sampleRate: sampleRate,
            channelCount: 2,
            configuration: VoiceBoostPreset.default.configuration
        )
        let delta = VoiceBoostFixtureGenerator.maximumDelta(pair.oracle, pair.vectorized)
        let peak = VoiceBoostFixtureGenerator.maxAbs(pair.oracle)
        #expect(delta <= 2e-3, "default-chain null \(delta) against peak \(peak)")

        let oracleMetrics = pair.oracleProcessor.metrics
        let vectorizedMetrics = pair.vectorizedProcessor.metrics
        if let oracleInput = oracleMetrics.integratedInputLUFS,
           let vectorizedInput = vectorizedMetrics.integratedInputLUFS {
            #expect(abs(oracleInput - vectorizedInput) <= 1e-9)
        } else {
            Issue.record("expected integrated input estimates on both engines")
        }
        #expect(abs(oracleMetrics.currentAutoGainDB - vectorizedMetrics.currentAutoGainDB) <= 1e-3)
        #expect(
            abs(oracleMetrics.currentCompressorReductionDB - vectorizedMetrics.currentCompressorReductionDB) <= 2e-2
        )
    }

    @Test
    func defaultChainMatchesOracleOnBlockSizeVariations() {
        let sampleRate = 48_000.0
        let fixture = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.2,
            sampleRate: sampleRate,
            duration: 3,
            channelCount: 2
        )
        for blockSize in [256, 1_024, 4_096] {
            let pair = processedPair(
                fixture: fixture,
                sampleRate: sampleRate,
                channelCount: 2,
                configuration: VoiceBoostPreset.default.configuration,
                blockSize: blockSize
            )
            let delta = VoiceBoostFixtureGenerator.maximumDelta(pair.oracle, pair.vectorized)
            #expect(delta <= 2e-3, "block \(blockSize) null \(delta)")
        }
    }

    @Test
    func silenceStaysSilentAndQuiescent() {
        let sampleRate = 48_000.0
        let fixture = VoiceBoostFixtureGenerator.silence(
            sampleRate: sampleRate,
            duration: 2,
            channelCount: 2
        )
        let pair = processedPair(
            fixture: fixture,
            sampleRate: sampleRate,
            channelCount: 2,
            configuration: VoiceBoostPreset.default.configuration
        )
        #expect(VoiceBoostFixtureGenerator.maxAbs(pair.vectorized) == 0)
        #expect(VoiceBoostFixtureGenerator.maxAbs(pair.oracle) == 0)
    }
}
