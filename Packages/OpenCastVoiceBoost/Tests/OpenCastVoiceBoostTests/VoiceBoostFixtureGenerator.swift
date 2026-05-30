import Foundation
@testable import OpenCastVoiceBoost

enum VoiceBoostFixtureGenerator {
    static func silence(
        sampleRate: Double,
        duration: Double,
        channelCount: Int
    ) -> [Float] {
        Array(repeating: 0, count: frameCount(sampleRate: sampleRate, duration: duration) * channelCount)
    }

    static func sine(
        frequency: Double,
        amplitude: Double,
        sampleRate: Double,
        duration: Double,
        channelCount: Int
    ) -> [Float] {
        let frames = frameCount(sampleRate: sampleRate, duration: duration)
        var buffer = [Float](repeating: 0, count: frames * channelCount)

        for frame in 0..<frames {
            let time = Double(frame) / sampleRate
            let sample = Float(amplitude * sin(2 * Double.pi * frequency * time))
            for channel in 0..<channelCount {
                buffer[frame * channelCount + channel] = sample
            }
        }

        return buffer
    }

    static func speechLike(
        amplitude: Double,
        sampleRate: Double,
        duration: Double,
        channelCount: Int
    ) -> [Float] {
        let frames = frameCount(sampleRate: sampleRate, duration: duration)
        var buffer = [Float](repeating: 0, count: frames * channelCount)

        for frame in 0..<frames {
            let time = Double(frame) / sampleRate
            let syllable = 0.55 + 0.45 * sin(2 * Double.pi * 3.2 * time)
            let carrier = 0.58 * sin(2 * Double.pi * 180 * time)
                + 0.28 * sin(2 * Double.pi * 720 * time)
                + 0.14 * sin(2 * Double.pi * 2400 * time)
            let sample = Float(amplitude * syllable * carrier)
            for channel in 0..<channelCount {
                let pan = channel == 0 ? 1.0 : 0.96
                buffer[frame * channelCount + channel] = Float(Double(sample) * pan)
            }
        }

        return buffer
    }

    static func alternatingSpeechLike(
        quietAmplitude: Double,
        loudAmplitude: Double,
        segmentDuration: Double,
        sampleRate: Double,
        duration: Double,
        channelCount: Int
    ) -> [Float] {
        let frames = frameCount(sampleRate: sampleRate, duration: duration)
        var buffer = [Float](repeating: 0, count: frames * channelCount)
        let segmentFrames = max(1, frameCount(sampleRate: sampleRate, duration: segmentDuration))

        for frame in 0..<frames {
            let segment = frame / segmentFrames
            let amplitude = segment.isMultiple(of: 2) ? quietAmplitude : loudAmplitude
            let time = Double(frame) / sampleRate
            let envelope = 0.5 + 0.5 * sin(2 * Double.pi * 4.0 * time)
            let carrier = 0.65 * sin(2 * Double.pi * 210 * time)
                + 0.25 * sin(2 * Double.pi * 900 * time)
                + 0.10 * sin(2 * Double.pi * 3100 * time)
            let sample = Float(amplitude * envelope * carrier)
            for channel in 0..<channelCount {
                buffer[frame * channelCount + channel] = sample
            }
        }

        return buffer
    }

    static func processInBlocks(
        _ buffer: inout [Float],
        processor: VoiceBoostProcessor,
        channelCount: Int,
        blockSize: Int = 1_024
    ) {
        let totalFrames = buffer.count / channelCount
        var offsetFrames = 0

        while offsetFrames < totalFrames {
            let frameCount = min(blockSize, totalFrames - offsetFrames)
            let offsetSamples = offsetFrames * channelCount
            let sampleCount = frameCount * channelCount

            buffer.withUnsafeMutableBufferPointer { pointer in
                let block = UnsafeMutableBufferPointer(
                    start: pointer.baseAddress! + offsetSamples,
                    count: sampleCount
                )
                processor.processInterleavedFloat32(block, frameCount: frameCount)
            }

            offsetFrames += frameCount
        }
    }

    static func rms(_ buffer: [Float]) -> Double {
        guard !buffer.isEmpty else {
            return 0
        }
        let sumSquares = buffer.reduce(0.0) { partialResult, sample in
            partialResult + Double(sample * sample)
        }
        return sqrt(sumSquares / Double(buffer.count))
    }

    static func maxAbs(_ buffer: [Float]) -> Double {
        buffer.reduce(0.0) { partialResult, sample in
            max(partialResult, abs(Double(sample)))
        }
    }

    static func maximumDelta(_ first: [Float], _ second: [Float]) -> Double {
        zip(first, second).reduce(0.0) { partialResult, pair in
            max(partialResult, abs(Double(pair.0 - pair.1)))
        }
    }

    static func maximumAdjacentStep(
        _ buffer: [Float],
        channelCount: Int,
        frameRange: Range<Int>? = nil
    ) -> Double {
        let totalFrames = buffer.count / channelCount
        guard totalFrames > 1 else {
            return 0
        }

        let range = frameRange ?? 1..<totalFrames
        let lowerBound = max(range.lowerBound, 1)
        let upperBound = min(range.upperBound, totalFrames)
        guard lowerBound < upperBound else {
            return 0
        }

        var maximumStep = 0.0
        for frame in lowerBound..<upperBound {
            for channel in 0..<channelCount {
                let sampleIndex = frame * channelCount + channel
                let previousIndex = sampleIndex - channelCount
                let step = abs(Double(buffer[sampleIndex] - buffer[previousIndex]))
                maximumStep = max(maximumStep, step)
            }
        }
        return maximumStep
    }

    static func linearAmplitude(db: Double) -> Double {
        pow(10, db / 20)
    }

    private static func frameCount(sampleRate: Double, duration: Double) -> Int {
        Int((sampleRate * duration).rounded())
    }
}
