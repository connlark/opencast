import Foundation
import OpenCastVoiceBoost

struct ProcessResult {
    var processedAudio: WAVAudio
    var inputMetrics: AudioMetrics
    var outputMetrics: AudioMetrics
    var comparisonMetrics: ComparisonMetrics
    var timeline: [TimelinePoint]
}

enum LabProcessor {
    static func process(_ audio: WAVAudio, preset: VoiceBoostPreset) -> ProcessResult {
        process(audio, configuration: preset.configuration)
    }

    static func process(_ audio: WAVAudio, configuration: VoiceBoostConfiguration) -> ProcessResult {
        var processed = audio.samples
        let processor = VoiceBoostProcessor(
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount,
            configuration: configuration
        )
        let blockFrames = max(1, Int((0.400 * audio.sampleRate).rounded()))
        let totalFrames = audio.frameCount
        var offsetFrames = 0
        var timeline: [TimelinePoint] = []
        let startTime = Date.timeIntervalSinceReferenceDate

        while offsetFrames < totalFrames {
            let frameCount = min(blockFrames, totalFrames - offsetFrames)
            let offsetSamples = offsetFrames * audio.channelCount
            let sampleCount = frameCount * audio.channelCount
            let inputBlock = Array(audio.samples[offsetSamples..<(offsetSamples + sampleCount)])

            processed.withUnsafeMutableBufferPointer { pointer in
                let block = UnsafeMutableBufferPointer(
                    start: pointer.baseAddress! + offsetSamples,
                    count: sampleCount
                )
                processor.processInterleavedFloat32(block, frameCount: frameCount)
            }

            let outputBlock = Array(processed[offsetSamples..<(offsetSamples + sampleCount)])
            let metrics = processor.metrics
            timeline.append(
                TimelinePoint(
                    timeSeconds: Double(offsetFrames) / audio.sampleRate,
                    inputLUFS: blockLUFS(inputBlock, sampleRate: audio.sampleRate, channelCount: audio.channelCount),
                    outputLUFS: blockLUFS(outputBlock, sampleRate: audio.sampleRate, channelCount: audio.channelCount),
                    autoGainDB: metrics.currentAutoGainDB,
                    compressorReductionDB: metrics.currentCompressorReductionDB,
                    limiterReductionDB: metrics.currentLimiterReductionDB,
                    inputTruePeakDBTP: VoiceBoostTruePeakAnalyzer.truePeakDBTP(
                        inputBlock,
                        channelCount: audio.channelCount
                    ),
                    outputTruePeakDBTP: VoiceBoostTruePeakAnalyzer.truePeakDBTP(
                        outputBlock,
                        channelCount: audio.channelCount
                    )
                )
            )

            offsetFrames += frameCount
        }

        let processingTime = Date.timeIntervalSinceReferenceDate - startTime
        let processedAudio = WAVAudio(
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount,
            samples: processed
        )
        let inputMetrics = AudioMetrics.make(audio: audio)
        let outputMetrics = AudioMetrics.make(
            audio: processedAudio,
            processingTimeSeconds: processingTime,
            timeline: timeline
        )
        let comparison = ComparisonMetrics(input: inputMetrics, output: outputMetrics)

        return ProcessResult(
            processedAudio: processedAudio,
            inputMetrics: inputMetrics,
            outputMetrics: outputMetrics,
            comparisonMetrics: comparison,
            timeline: timeline
        )
    }

    private static func blockLUFS(
        _ samples: [Float],
        sampleRate: Double,
        channelCount: Int
    ) -> Double? {
        let analysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            samples,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        return analysis.momentaryLUFS.first { $0.isFinite }
    }
}
