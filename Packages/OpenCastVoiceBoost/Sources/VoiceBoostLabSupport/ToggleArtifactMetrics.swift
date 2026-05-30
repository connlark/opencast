import Foundation

struct ToggleArtifactMetrics: Codable {
    var toggleIntervalSeconds: Double
    var windowSeconds: Double
    var transitionCount: Int
    var maxFileAdjacentStep: Double
    var maxBoundaryAdjacentStep: Double
    var p95BoundaryAdjacentStep: Double?
    var maxBoundaryToFileStepRatio: Double?
    var transitions: [ToggleArtifactTransitionMetrics]

    static func make(
        audio: WAVAudio,
        toggleIntervalSeconds: Double,
        windowSeconds: Double = 0.050
    ) -> ToggleArtifactMetrics {
        let maxFileAdjacentStep = maximumAdjacentStep(
            audio: audio,
            frameRange: 1..<audio.frameCount
        )
        let windowFrames = max(1, Int((windowSeconds * audio.sampleRate).rounded()))
        var transitions: [ToggleArtifactTransitionMetrics] = []
        var transitionIndex = 1

        while Double(transitionIndex) * toggleIntervalSeconds < audio.duration {
            let timeSeconds = Double(transitionIndex) * toggleIntervalSeconds
            let transitionFrame = Int((timeSeconds * audio.sampleRate).rounded())
            let frameRange = (transitionFrame - windowFrames)..<(transitionFrame + windowFrames)
            let maxBoundaryAdjacentStep = maximumAdjacentStep(audio: audio, frameRange: frameRange)
            let ratio = ratio(maxBoundaryAdjacentStep, maxFileAdjacentStep)
            transitions.append(
                ToggleArtifactTransitionMetrics(
                    transitionIndex: transitionIndex,
                    timeSeconds: timeSeconds,
                    becameEnabled: !transitionIndex.isMultiple(of: 2),
                    maxAdjacentStep: maxBoundaryAdjacentStep,
                    boundaryToFileStepRatio: ratio
                )
            )
            transitionIndex += 1
        }

        let boundarySteps = transitions.map(\.maxAdjacentStep)
        let maxBoundaryAdjacentStep = boundarySteps.max() ?? 0
        return ToggleArtifactMetrics(
            toggleIntervalSeconds: toggleIntervalSeconds,
            windowSeconds: Double(windowFrames) / audio.sampleRate,
            transitionCount: transitions.count,
            maxFileAdjacentStep: maxFileAdjacentStep,
            maxBoundaryAdjacentStep: maxBoundaryAdjacentStep,
            p95BoundaryAdjacentStep: percentile(boundarySteps, 0.95),
            maxBoundaryToFileStepRatio: ratio(maxBoundaryAdjacentStep, maxFileAdjacentStep),
            transitions: transitions
        )
    }

    private static func maximumAdjacentStep(
        audio: WAVAudio,
        frameRange: Range<Int>
    ) -> Double {
        guard audio.frameCount > 1 else {
            return 0
        }

        let lowerBound = max(1, frameRange.lowerBound)
        let upperBound = min(audio.frameCount, frameRange.upperBound)
        guard lowerBound < upperBound else {
            return 0
        }

        var maximumStep = 0.0
        for frame in lowerBound..<upperBound {
            for channel in 0..<audio.channelCount {
                let sampleIndex = frame * audio.channelCount + channel
                let previousIndex = sampleIndex - audio.channelCount
                let step = abs(Double(audio.samples[sampleIndex] - audio.samples[previousIndex]))
                maximumStep = max(maximumStep, step)
            }
        }
        return maximumStep
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

    private static func ratio(_ numerator: Double, _ denominator: Double) -> Double? {
        guard numerator.isFinite, denominator.isFinite, denominator > 0 else {
            return nil
        }
        return numerator / denominator
    }
}

struct ToggleArtifactTransitionMetrics: Codable {
    var transitionIndex: Int
    var timeSeconds: Double
    var becameEnabled: Bool
    var maxAdjacentStep: Double
    var boundaryToFileStepRatio: Double?
}
