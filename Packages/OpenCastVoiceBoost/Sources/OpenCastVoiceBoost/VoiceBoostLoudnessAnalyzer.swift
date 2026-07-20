import Foundation

public enum VoiceBoostLoudnessAnalyzer {
    /// Sub-blocks per momentary (400 ms) and short-term (3 s) window on the
    /// 100 ms analysis grid. Matches the realtime engine's geometry so both
    /// measure identical gating blocks on the same fixture.
    private static let momentarySubBlocks = 4
    private static let shortTermSubBlocks = 30

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
        let subBlocks = subBlockEnergies(
            weighted,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        let momentaryEnergies = slidingWindowMeans(subBlocks, windowSubBlocks: momentarySubBlocks)
        let shortTermEnergies = slidingWindowMeans(subBlocks, windowSubBlocks: shortTermSubBlocks)

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

    /// Channel-summed mean-square energy per 100 ms sub-block
    /// (`ceil(0.1 * sampleRate)` frames); a trailing partial sub-block is
    /// discarded, mirroring the gating-block rule in EBU Tech 3341.
    private static func subBlockEnergies(
        _ weighted: [Double],
        sampleRate: Double,
        channelCount: Int
    ) -> [Double] {
        let frameCount = weighted.count / channelCount
        let subBlockFrames = max(1, Int((0.1 * sampleRate).rounded(.up)))
        let subBlockCount = frameCount / subBlockFrames
        var energies = [Double]()
        energies.reserveCapacity(subBlockCount)

        for subBlock in 0..<subBlockCount {
            var sumSquares = 0.0
            let startFrame = subBlock * subBlockFrames
            for frame in startFrame..<(startFrame + subBlockFrames) {
                for channel in 0..<channelCount {
                    let sample = weighted[frame * channelCount + channel]
                    sumSquares += sample * sample
                }
            }
            energies.append(sumSquares / Double(subBlockFrames))
        }

        return energies
    }

    private static func slidingWindowMeans(
        _ subBlocks: [Double],
        windowSubBlocks: Int
    ) -> [Double] {
        guard subBlocks.count >= windowSubBlocks else {
            return []
        }

        var means = [Double]()
        means.reserveCapacity(subBlocks.count - windowSubBlocks + 1)
        for start in 0...(subBlocks.count - windowSubBlocks) {
            var sum = 0.0
            for offset in 0..<windowSubBlocks {
                sum += subBlocks[start + offset]
            }
            means.append(sum / Double(windowSubBlocks))
        }
        return means
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
