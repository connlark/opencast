import Foundation

struct ReferenceAlignmentMetrics: Codable {
    var inputStartFrame: Int
    var referenceStartFrame: Int
    var overlapFrameCount: Int
    var inputStartSeconds: Double
    var referenceStartSeconds: Double
    var overlapSeconds: Double
    var estimatedReferenceDelaySeconds: Double
    var correlation: Double
    var hopSeconds: Double
    var maxLagSeconds: Double
}

struct ReferenceAlignmentBundle {
    var metrics: ReferenceAlignmentMetrics
    var alignedDryAudio: WAVAudio
    var alignedBoostedAudio: WAVAudio
    var alignedReferenceAudio: WAVAudio
    var alignedDryMetrics: AudioMetrics
    var alignedBoostedMetrics: AudioMetrics
    var alignedReferenceMetrics: AudioMetrics
    var alignedDryReferenceComparison: ComparisonMetrics
    var alignedBoostedReferenceComparison: ComparisonMetrics
}

enum ReferenceAlignment {
    static func make(
        dryAudio: WAVAudio,
        boostedAudio: WAVAudio,
        referenceAudio: WAVAudio,
        hopSeconds: Double = 0.020,
        maxLagSeconds: Double = 5
    ) -> ReferenceAlignmentBundle? {
        guard dryAudio.sampleRate == referenceAudio.sampleRate,
              dryAudio.channelCount == referenceAudio.channelCount,
              dryAudio.sampleRate == boostedAudio.sampleRate,
              dryAudio.channelCount == boostedAudio.channelCount
        else {
            return nil
        }

        let hopFrames = max(1, Int((hopSeconds * dryAudio.sampleRate).rounded()))
        let inputEnvelope = envelope(audio: dryAudio, hopFrames: hopFrames)
        let referenceEnvelope = envelope(audio: referenceAudio, hopFrames: hopFrames)
        guard let match = bestMatch(
            input: inputEnvelope,
            reference: referenceEnvelope,
            maxLagBins: max(1, Int((maxLagSeconds / hopSeconds).rounded()))
        ) else {
            return nil
        }

        let inputStartFrame = match.inputStartBin * hopFrames
        let referenceStartFrame = match.referenceStartBin * hopFrames
        let availableInputFrames = dryAudio.frameCount - inputStartFrame
        let availableReferenceFrames = referenceAudio.frameCount - referenceStartFrame
        let overlapFrameCount = min(availableInputFrames, availableReferenceFrames)
        guard overlapFrameCount > 0 else {
            return nil
        }

        let alignedDry = dryAudio.cropped(startFrame: inputStartFrame, frameCount: overlapFrameCount)
        let alignedBoosted = boostedAudio.cropped(startFrame: inputStartFrame, frameCount: overlapFrameCount)
        let alignedReference = referenceAudio.cropped(
            startFrame: referenceStartFrame,
            frameCount: overlapFrameCount
        )
        let alignedDryMetrics = AudioMetrics.make(audio: alignedDry)
        let alignedBoostedMetrics = AudioMetrics.make(audio: alignedBoosted)
        let alignedReferenceMetrics = AudioMetrics.make(audio: alignedReference)

        return ReferenceAlignmentBundle(
            metrics: ReferenceAlignmentMetrics(
                inputStartFrame: inputStartFrame,
                referenceStartFrame: referenceStartFrame,
                overlapFrameCount: overlapFrameCount,
                inputStartSeconds: Double(inputStartFrame) / dryAudio.sampleRate,
                referenceStartSeconds: Double(referenceStartFrame) / referenceAudio.sampleRate,
                overlapSeconds: Double(overlapFrameCount) / dryAudio.sampleRate,
                estimatedReferenceDelaySeconds: Double(referenceStartFrame - inputStartFrame) / dryAudio.sampleRate,
                correlation: match.correlation,
                hopSeconds: Double(hopFrames) / dryAudio.sampleRate,
                maxLagSeconds: maxLagSeconds
            ),
            alignedDryAudio: alignedDry,
            alignedBoostedAudio: alignedBoosted,
            alignedReferenceAudio: alignedReference,
            alignedDryMetrics: alignedDryMetrics,
            alignedBoostedMetrics: alignedBoostedMetrics,
            alignedReferenceMetrics: alignedReferenceMetrics,
            alignedDryReferenceComparison: ComparisonMetrics(
                input: alignedReferenceMetrics,
                output: alignedDryMetrics
            ),
            alignedBoostedReferenceComparison: ComparisonMetrics(
                input: alignedReferenceMetrics,
                output: alignedBoostedMetrics
            )
        )
    }

    private struct Match {
        var inputStartBin: Int
        var referenceStartBin: Int
        var correlation: Double
    }

    private static func envelope(audio: WAVAudio, hopFrames: Int) -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(audio.frameCount / hopFrames + 1)

        var frame = 0
        while frame < audio.frameCount {
            let frameCount = min(hopFrames, audio.frameCount - frame)
            let startSample = frame * audio.channelCount
            let sampleCount = frameCount * audio.channelCount
            let sum = audio.samples[startSample..<startSample + sampleCount].reduce(0.0) {
                partial, sample in
                sample.isFinite ? partial + Double(abs(sample)) : partial
            }
            values.append(sum / Double(sampleCount))
            frame += frameCount
        }

        return values
    }

    private static func bestMatch(
        input: [Double],
        reference: [Double],
        maxLagBins: Int
    ) -> Match? {
        guard input.count >= 4, reference.count >= 4 else {
            return nil
        }

        var best: Match?
        let minimumOverlap = max(4, min(input.count, reference.count) / 3)
        for lag in -maxLagBins...maxLagBins {
            let inputStart = max(0, -lag)
            let referenceStart = max(0, lag)
            let count = min(input.count - inputStart, reference.count - referenceStart)
            guard count >= minimumOverlap else {
                continue
            }

            let correlation = correlation(
                input: input,
                inputStart: inputStart,
                reference: reference,
                referenceStart: referenceStart,
                count: count
            )
            guard correlation.isFinite else {
                continue
            }

            if best.map({ correlation > $0.correlation }) ?? true {
                best = Match(
                    inputStartBin: inputStart,
                    referenceStartBin: referenceStart,
                    correlation: correlation
                )
            }
        }

        return best
    }

    private static func correlation(
        input: [Double],
        inputStart: Int,
        reference: [Double],
        referenceStart: Int,
        count: Int
    ) -> Double {
        var inputSum = 0.0
        var referenceSum = 0.0
        var inputSquares = 0.0
        var referenceSquares = 0.0
        var cross = 0.0

        for index in 0..<count {
            let inputValue = input[inputStart + index]
            let referenceValue = reference[referenceStart + index]
            inputSum += inputValue
            referenceSum += referenceValue
            inputSquares += inputValue * inputValue
            referenceSquares += referenceValue * referenceValue
            cross += inputValue * referenceValue
        }

        let sampleCount = Double(count)
        let inputVariance = inputSquares - inputSum * inputSum / sampleCount
        let referenceVariance = referenceSquares - referenceSum * referenceSum / sampleCount
        let denominator = sqrt(inputVariance * referenceVariance)
        guard denominator > 0 else {
            return .nan
        }

        return (cross - inputSum * referenceSum / sampleCount) / denominator
    }
}
