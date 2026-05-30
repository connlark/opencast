import Foundation
import OpenCastVoiceBoost

struct AudioMetrics: Codable {
    var durationSeconds: Double
    var sampleRate: Double
    var channelCount: Int
    var integratedLUFS: Double?
    var ungatedIntegratedLUFS: Double?
    var momentaryLUFS: Summary
    var shortTermLUFS: Summary
    var truePeakDBTP: Double?
    var samplePeakDBFS: Double?
    var rmsDBFS: Double?
    var crestFactorDB: Double?
    var clippedSampleCount: Int
    var nanInfSampleCount: Int
    var processingTimeSeconds: Double?
    var realtimeFactor: Double?
    var maxAutoGainDB: Double?
    var p95AutoGainDB: Double?
    var maxCompressorReductionDB: Double?
    var p95CompressorReductionDB: Double?
    var maxLimiterReductionDB: Double?
    var p95LimiterReductionDB: Double?

    static func make(
        audio: WAVAudio,
        processingTimeSeconds: Double? = nil,
        timeline: [TimelinePoint] = []
    ) -> AudioMetrics {
        let analysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            audio.samples,
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount
        )
        let samplePeak = VoiceBoostTruePeakAnalyzer.samplePeakDBFS(audio.samples)
        let truePeak = VoiceBoostTruePeakAnalyzer.truePeakDBTP(
            audio.samples,
            channelCount: audio.channelCount
        )
        let rms = rmsDBFS(audio.samples)
        let crest = finiteOrNil(samplePeak - (rms ?? samplePeak))
        let autoGain = timeline.map(\.autoGainDB)
        let compressor = timeline.map(\.compressorReductionDB)
        let limiter = timeline.map(\.limiterReductionDB)

        return AudioMetrics(
            durationSeconds: audio.duration,
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount,
            integratedLUFS: finiteOrNil(analysis.integratedLUFS),
            ungatedIntegratedLUFS: finiteOrNil(analysis.ungatedIntegratedLUFS),
            momentaryLUFS: Summary(values: analysis.momentaryLUFS),
            shortTermLUFS: Summary(values: analysis.shortTermLUFS),
            truePeakDBTP: finiteOrNil(truePeak),
            samplePeakDBFS: finiteOrNil(samplePeak),
            rmsDBFS: rms,
            crestFactorDB: crest,
            clippedSampleCount: audio.samples.count { abs($0) >= 1 },
            nanInfSampleCount: audio.samples.count { !$0.isFinite },
            processingTimeSeconds: processingTimeSeconds,
            realtimeFactor: processingTimeSeconds.map { audio.duration / max($0, 0.000_001) },
            maxAutoGainDB: autoGain.max(),
            p95AutoGainDB: percentile(autoGain, 0.95),
            maxCompressorReductionDB: compressor.max(),
            p95CompressorReductionDB: percentile(compressor, 0.95),
            maxLimiterReductionDB: limiter.max(),
            p95LimiterReductionDB: percentile(limiter, 0.95)
        )
    }

    private static func rmsDBFS(_ samples: [Float]) -> Double? {
        guard !samples.isEmpty else {
            return nil
        }

        let finiteSamples = samples.filter(\.isFinite)
        guard !finiteSamples.isEmpty else {
            return nil
        }

        let sumSquares = finiteSamples.reduce(0.0) { partialResult, sample in
            partialResult + Double(sample * sample)
        }
        let rms = sqrt(sumSquares / Double(finiteSamples.count))
        return finiteOrNil(VoiceBoostLevel.decibels(amplitude: rms))
    }

    private static func finiteOrNil(_ value: Double?) -> Double? {
        guard let value else {
            return nil
        }
        return finiteOrNil(value)
    }

    private static func finiteOrNil(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        let finiteValues = values.filter(\.isFinite).sorted()
        guard !finiteValues.isEmpty else {
            return nil
        }

        let index = min(
            finiteValues.count - 1,
            max(0, Int((Double(finiteValues.count - 1) * percentile).rounded()))
        )
        return finiteValues[index]
    }
}

struct Summary: Codable {
    var min: Double?
    var p50: Double?
    var p95: Double?
    var max: Double?

    init(values: [Double]) {
        let finiteValues = values.filter(\.isFinite).sorted()
        min = finiteValues.first
        p50 = Summary.percentile(finiteValues, 0.50)
        p95 = Summary.percentile(finiteValues, 0.95)
        max = finiteValues.last
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        let index = Swift.min(
            values.count - 1,
            Swift.max(0, Int((Double(values.count - 1) * percentile).rounded()))
        )
        return values[index]
    }
}
