import Foundation

enum FixtureFactory {
    static func writeFixtures(to outputDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let sampleRate = 48_000.0
        let fixtures: [(String, WAVAudio)] = [
            (
                "silence.wav",
                WAVAudio(
                    sampleRate: sampleRate,
                    channelCount: 1,
                    samples: silence(sampleRate: sampleRate, duration: 2, channelCount: 1)
                )
            ),
            (
                "near_full_scale_sine.wav",
                WAVAudio(
                    sampleRate: sampleRate,
                    channelCount: 1,
                    samples: sine(
                        frequency: 997,
                        amplitude: 0.95,
                        sampleRate: sampleRate,
                        duration: 2,
                        channelCount: 1
                    )
                )
            ),
            (
                "speech_like.wav",
                WAVAudio(
                    sampleRate: sampleRate,
                    channelCount: 2,
                    samples: speechLike(
                        amplitude: 0.10,
                        sampleRate: sampleRate,
                        duration: 8,
                        channelCount: 2
                    )
                )
            ),
            (
                "quiet_loud_speech_like.wav",
                WAVAudio(
                    sampleRate: sampleRate,
                    channelCount: 2,
                    samples: alternatingSpeechLike(
                        quietAmplitude: 0.025,
                        loudAmplitude: 0.35,
                        segmentDuration: 1,
                        sampleRate: sampleRate,
                        duration: 10,
                        channelCount: 2
                    )
                )
            ),
            (
                "intersample_stress.wav",
                WAVAudio(
                    sampleRate: sampleRate,
                    channelCount: 1,
                    samples: intersampleStress(amplitude: 0.85, repetitions: 6_000)
                )
            )
        ]

        for (filename, audio) in fixtures {
            try WAVFile.write(audio, to: outputDirectory.appending(path: filename))
        }
    }

    static func silence(sampleRate: Double, duration: Double, channelCount: Int) -> [Float] {
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
        var samples = [Float](repeating: 0, count: frames * channelCount)

        for frame in 0..<frames {
            let time = Double(frame) / sampleRate
            let sample = Float(amplitude * sin(2 * Double.pi * frequency * time))
            for channel in 0..<channelCount {
                samples[frame * channelCount + channel] = sample
            }
        }

        return samples
    }

    static func speechLike(
        amplitude: Double,
        sampleRate: Double,
        duration: Double,
        channelCount: Int
    ) -> [Float] {
        let frames = frameCount(sampleRate: sampleRate, duration: duration)
        var samples = [Float](repeating: 0, count: frames * channelCount)

        for frame in 0..<frames {
            let time = Double(frame) / sampleRate
            let syllable = 0.55 + 0.45 * sin(2 * Double.pi * 3.2 * time)
            let carrier = 0.58 * sin(2 * Double.pi * 180 * time)
                + 0.28 * sin(2 * Double.pi * 720 * time)
                + 0.14 * sin(2 * Double.pi * 2400 * time)
            let sample = Float(amplitude * syllable * carrier)

            for channel in 0..<channelCount {
                let pan = channel == 0 ? 1.0 : 0.96
                samples[frame * channelCount + channel] = Float(Double(sample) * pan)
            }
        }

        return samples
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
        let segmentFrames = max(1, frameCount(sampleRate: sampleRate, duration: segmentDuration))
        var samples = [Float](repeating: 0, count: frames * channelCount)

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
                samples[frame * channelCount + channel] = sample
            }
        }

        return samples
    }

    static func intersampleStress(amplitude: Float, repetitions: Int) -> [Float] {
        let pattern: [Float] = [
            0,
            amplitude,
            amplitude,
            0,
            0,
            -amplitude,
            -amplitude,
            0
        ]
        return Array(repeating: pattern, count: repetitions).flatMap { $0 }
    }

    private static func frameCount(sampleRate: Double, duration: Double) -> Int {
        Int((sampleRate * duration).rounded())
    }
}
