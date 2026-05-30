import Foundation

struct WAVAudio {
    var sampleRate: Double
    var channelCount: Int
    var samples: [Float]

    var frameCount: Int {
        samples.count / channelCount
    }

    var duration: Double {
        Double(frameCount) / sampleRate
    }

    func cropped(startFrame: Int, frameCount requestedFrameCount: Int) -> WAVAudio {
        let safeStartFrame = min(max(0, startFrame), frameCount)
        let safeFrameCount = min(max(0, requestedFrameCount), frameCount - safeStartFrame)
        let startSample = safeStartFrame * channelCount
        let endSample = startSample + safeFrameCount * channelCount
        return WAVAudio(
            sampleRate: sampleRate,
            channelCount: channelCount,
            samples: Array(samples[startSample..<endSample])
        )
    }
}
