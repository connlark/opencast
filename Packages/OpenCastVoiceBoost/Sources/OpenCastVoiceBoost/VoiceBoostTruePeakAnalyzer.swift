import Foundation

public enum VoiceBoostTruePeakAnalyzer {
    public static func samplePeakDBFS(_ buffer: [Float]) -> Double {
        VoiceBoostLevel.decibels(amplitude: buffer.reduce(0.0) { partialResult, sample in
            max(partialResult, abs(Double(sample)))
        })
    }

    public static func truePeakDBTP(
        _ buffer: [Float],
        channelCount: Int,
        oversampleFactor: Int = 4
    ) -> Double {
        precondition(channelCount > 0)
        precondition(buffer.count.isMultiple(of: channelCount))
        let peak = truePeakAmplitude(
            buffer,
            channelCount: channelCount,
            oversampleFactor: oversampleFactor
        )
        return VoiceBoostLevel.decibels(amplitude: peak)
    }

    public static func truePeakAmplitude(
        _ buffer: [Float],
        channelCount: Int,
        oversampleFactor: Int = 4
    ) -> Double {
        precondition(channelCount > 0)
        precondition(buffer.count.isMultiple(of: channelCount))
        let factor = max(1, oversampleFactor)
        let frameCount = buffer.count / channelCount
        guard frameCount > 0 else {
            return 0
        }

        var peak = 0.0
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                peak = max(peak, abs(Double(buffer[frame * channelCount + channel])))
            }

            guard frameCount > 1, factor > 1 else {
                continue
            }

            for frame in 0..<(frameCount - 1) {
                let y0 = sample(buffer, frame: frame - 1, channel: channel, channelCount: channelCount)
                let y1 = sample(buffer, frame: frame, channel: channel, channelCount: channelCount)
                let y2 = sample(buffer, frame: frame + 1, channel: channel, channelCount: channelCount)
                let y3 = sample(buffer, frame: frame + 2, channel: channel, channelCount: channelCount)

                for step in 1..<factor {
                    let t = Double(step) / Double(factor)
                    let interpolated = catmullRom(y0: y0, y1: y1, y2: y2, y3: y3, t: t)
                    peak = max(peak, abs(interpolated))
                }
            }
        }

        return peak
    }

    private static func sample(
        _ buffer: [Float],
        frame: Int,
        channel: Int,
        channelCount: Int
    ) -> Double {
        let frameCount = buffer.count / channelCount
        let clampedFrame = min(max(frame, 0), frameCount - 1)
        return Double(buffer[clampedFrame * channelCount + channel])
    }

    private static func catmullRom(
        y0: Double,
        y1: Double,
        y2: Double,
        y3: Double,
        t: Double
    ) -> Double {
        0.5 * (
            2 * y1
                + (-y0 + y2) * t
                + (2 * y0 - 5 * y1 + 4 * y2 - y3) * t * t
                + (-y0 + 3 * y1 - 3 * y2 + y3) * t * t * t
        )
    }
}
