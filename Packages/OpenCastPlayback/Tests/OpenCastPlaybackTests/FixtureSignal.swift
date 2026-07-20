import Foundation

/// Deterministic test signals for tap-level processing tests.
enum FixtureSignal {
    static func speechLike(
        amplitude: Double,
        sampleRate: Double,
        duration: Double,
        channelCount: Int
    ) -> [Float] {
        let frames = Int((sampleRate * duration).rounded())
        var buffer = [Float](repeating: 0, count: frames * channelCount)

        for frame in 0..<frames {
            let time = Double(frame) / sampleRate
            let syllable = 0.55 + 0.45 * sin(2 * Double.pi * 3.2 * time)
            let carrier = 0.58 * sin(2 * Double.pi * 180 * time)
                + 0.28 * sin(2 * Double.pi * 720 * time)
                + 0.14 * sin(2 * Double.pi * 2400 * time)
            let sample = Float(amplitude * syllable * carrier)
            for channel in 0..<channelCount {
                buffer[frame * channelCount + channel] = sample
            }
        }

        return buffer
    }

    static func sine(
        frequency: Double,
        amplitude: Double,
        sampleRate: Double,
        frameCount: Int
    ) -> [Float] {
        (0..<frameCount).map { frame in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
        }
    }
}
