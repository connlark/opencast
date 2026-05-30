import Dispatch
import Foundation
import OpenCastVoiceBoost

enum BenchmarkRunner {
    static func run(
        durationSeconds: Double,
        sampleRate: Double,
        channelCount: Int,
        blockFrameCount: Int,
        configuration: VoiceBoostConfiguration
    ) throws -> BenchmarkMetrics {
        guard durationSeconds.isFinite && durationSeconds > 0 else {
            throw LabError.invalidArguments("Benchmark duration must be positive.")
        }
        guard sampleRate.isFinite && sampleRate > 0 else {
            throw LabError.invalidArguments("Benchmark sample rate must be positive.")
        }
        guard (1...2).contains(channelCount) else {
            throw LabError.invalidArguments("Benchmark channel count must be 1 or 2.")
        }
        guard blockFrameCount > 0 else {
            throw LabError.invalidArguments("Benchmark block frame count must be positive.")
        }

        let totalFrames = Int((sampleRate * durationSeconds).rounded())
        let pattern = FixtureFactory.alternatingSpeechLike(
            quietAmplitude: 0.025,
            loudAmplitude: 0.35,
            segmentDuration: 0.5,
            sampleRate: sampleRate,
            duration: 4,
            channelCount: channelCount
        )
        let patternFrames = pattern.count / channelCount
        var block = [Float](repeating: 0, count: blockFrameCount * channelCount)
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: configuration
        )

        let wallStart = Date.timeIntervalSinceReferenceDate
        var offsetFrames = 0
        var blockCount = 0
        var dspNanoseconds: UInt64 = 0
        var maxProcessCallNanoseconds: UInt64 = 0
        var peakAbs = 0.0
        var nanInfSampleCount = 0

        while offsetFrames < totalFrames {
            let frameCount = min(blockFrameCount, totalFrames - offsetFrames)
            let sampleCount = frameCount * channelCount
            fill(
                &block,
                sampleCount: sampleCount,
                channelCount: channelCount,
                source: pattern,
                sourceFrameCount: patternFrames,
                frameOffset: offsetFrames
            )

            let processStart = DispatchTime.now().uptimeNanoseconds
            block.withUnsafeMutableBufferPointer { pointer in
                let slice = UnsafeMutableBufferPointer(
                    start: pointer.baseAddress!,
                    count: sampleCount
                )
                processor.processInterleavedFloat32(slice, frameCount: frameCount)
            }
            let processDuration = DispatchTime.now().uptimeNanoseconds - processStart

            dspNanoseconds += processDuration
            maxProcessCallNanoseconds = max(maxProcessCallNanoseconds, processDuration)
            blockCount += 1

            for sample in block.prefix(sampleCount) {
                if sample.isFinite {
                    peakAbs = max(peakAbs, abs(Double(sample)))
                } else {
                    nanInfSampleCount += 1
                }
            }

            offsetFrames += frameCount
        }

        let wallTime = Date.timeIntervalSinceReferenceDate - wallStart
        let dspSeconds = Double(dspNanoseconds) / 1_000_000_000
        let metrics = processor.metrics

        return BenchmarkMetrics(
            durationSeconds: durationSeconds,
            sampleRate: sampleRate,
            channelCount: channelCount,
            blockFrameCount: blockFrameCount,
            processedFrames: totalFrames,
            blockCount: blockCount,
            dspProcessingTimeSeconds: dspSeconds,
            wallTimeSeconds: wallTime,
            realtimeFactor: durationSeconds / max(dspSeconds, 0.000_001),
            averageProcessCallMicroseconds: Double(dspNanoseconds) / Double(max(blockCount, 1)) / 1_000,
            maxProcessCallMicroseconds: Double(maxProcessCallNanoseconds) / 1_000,
            averageNanosecondsPerFrame: Double(dspNanoseconds) / Double(max(totalFrames, 1)),
            peakAbs: peakAbs,
            nanInfSampleCount: nanInfSampleCount,
            estimatedInputLUFS: metrics.estimatedInputLUFS,
            estimatedOutputLUFS: metrics.estimatedOutputLUFS,
            currentAutoGainDB: metrics.currentAutoGainDB,
            currentCompressorReductionDB: metrics.currentCompressorReductionDB,
            currentLimiterReductionDB: metrics.currentLimiterReductionDB,
            outputTruePeakDBTP: metrics.outputTruePeakDBTP
        )
    }

    private static func fill(
        _ block: inout [Float],
        sampleCount: Int,
        channelCount: Int,
        source: [Float],
        sourceFrameCount: Int,
        frameOffset: Int
    ) {
        for frame in 0..<(sampleCount / channelCount) {
            let sourceFrame = (frameOffset + frame) % sourceFrameCount
            for channel in 0..<channelCount {
                block[frame * channelCount + channel] = source[sourceFrame * channelCount + channel]
            }
        }
    }
}
