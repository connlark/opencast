import Foundation

public enum VoiceBoostLoudnessAnalyzer {
    public static func analyzeInterleavedFloat32(
        _ buffer: [Float],
        sampleRate: Double,
        channelCount: Int
    ) -> VoiceBoostLoudnessAnalysis {
        precondition(sampleRate > 0 && sampleRate.isFinite)
        precondition((1...2).contains(channelCount))
        precondition(buffer.count.isMultiple(of: channelCount))

        let weighted = kWeightedInterleavedFloat32(
            buffer,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        let momentaryEnergies = windowEnergies(
            weighted,
            sampleRate: sampleRate,
            channelCount: channelCount,
            windowSeconds: 0.400,
            stepSeconds: 0.100
        )
        let shortTermEnergies = windowEnergies(
            weighted,
            sampleRate: sampleRate,
            channelCount: channelCount,
            windowSeconds: 3.0,
            stepSeconds: 0.100
        )

        let momentary = momentaryEnergies.map(VoiceBoostLevel.loudness(meanSquare:))
        let shortTerm = shortTermEnergies.map(VoiceBoostLevel.loudness(meanSquare:))
        let absoluteGatedEnergies = momentaryEnergies.filter {
            VoiceBoostLevel.loudness(meanSquare: $0) > -70
        }
        let ungated = absoluteGatedEnergies.isEmpty
            ? nil
            : VoiceBoostLevel.loudness(meanSquare: absoluteGatedEnergies.average)

        let integrated: Double?
        if let ungated {
            let relativeThreshold = ungated - 10
            let gated = absoluteGatedEnergies.filter {
                VoiceBoostLevel.loudness(meanSquare: $0) > relativeThreshold
            }
            integrated = gated.isEmpty
                ? nil
                : VoiceBoostLevel.loudness(meanSquare: gated.average)
        } else {
            integrated = nil
        }

        return VoiceBoostLoudnessAnalysis(
            momentaryLUFS: momentary,
            shortTermLUFS: shortTerm,
            integratedLUFS: integrated,
            ungatedIntegratedLUFS: ungated
        )
    }

    static func kWeightedInterleavedFloat32(
        _ buffer: [Float],
        sampleRate: Double,
        channelCount: Int
    ) -> [Double] {
        var preFilters = (0..<channelCount).map { _ in
            VoiceBoostBiquad.bs1770PreFilter(sampleRate: sampleRate)
        }
        var rlbFilters = (0..<channelCount).map { _ in
            VoiceBoostBiquad.bs1770RLBFilter(sampleRate: sampleRate)
        }
        var weighted = [Double](repeating: 0, count: buffer.count)
        let frameCount = buffer.count / channelCount

        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let index = frame * channelCount + channel
                let sample = Double(buffer[index])
                guard sample.isFinite else {
                    weighted[index] = 0
                    continue
                }

                let prefiltered = preFilters[channel].process(sample)
                weighted[index] = rlbFilters[channel].process(prefiltered)
            }
        }

        return weighted
    }

    private static func windowEnergies(
        _ weighted: [Double],
        sampleRate: Double,
        channelCount: Int,
        windowSeconds: Double,
        stepSeconds: Double
    ) -> [Double] {
        let frameCount = weighted.count / channelCount
        let windowFrames = max(1, Int((windowSeconds * sampleRate).rounded()))
        let stepFrames = max(1, Int((stepSeconds * sampleRate).rounded()))
        guard frameCount >= windowFrames else {
            return []
        }

        var energies: [Double] = []
        var startFrame = 0

        while startFrame + windowFrames <= frameCount {
            var sumSquares = 0.0
            for frame in startFrame..<(startFrame + windowFrames) {
                for channel in 0..<channelCount {
                    let sample = weighted[frame * channelCount + channel]
                    sumSquares += sample * sample
                }
            }
            energies.append(sumSquares / Double(windowFrames))
            startFrame += stepFrames
        }

        return energies
    }
}

private extension Array where Element == Double {
    var average: Double {
        guard !isEmpty else {
            return 0
        }
        return reduce(0, +) / Double(count)
    }
}
