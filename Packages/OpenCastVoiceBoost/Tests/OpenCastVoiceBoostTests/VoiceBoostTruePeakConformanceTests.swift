import Foundation
import Testing
@testable import OpenCastVoiceBoost

/// EBU Tech 3341 minimum-requirements test signals for true-peak meters
/// (cases 15-23), synthesized per the table and measured against both the
/// offline analyzer and the runtime streaming meter (which share the C
/// Annex 2 polyphase FIR kernel). Tolerance is +0.2/-0.4 dB per case.
struct VoiceBoostTruePeakConformanceTests {
    private struct SineCase {
        var name: String
        var frequencyRatio: Double
        var amplitude: Double
        var phaseDegrees: Double
        var expectedDBTP: Double
    }

    private static let sineCases = [
        SineCase(name: "15", frequencyRatio: 1.0 / 4.0, amplitude: 0.5, phaseDegrees: 0.0, expectedDBTP: -6.0),
        SineCase(name: "16", frequencyRatio: 1.0 / 4.0, amplitude: 0.5, phaseDegrees: 45.0, expectedDBTP: -6.0),
        SineCase(name: "17", frequencyRatio: 1.0 / 6.0, amplitude: 0.5, phaseDegrees: 60.0, expectedDBTP: -6.0),
        SineCase(name: "18", frequencyRatio: 1.0 / 8.0, amplitude: 0.5, phaseDegrees: 67.5, expectedDBTP: -6.0),
        SineCase(name: "19", frequencyRatio: 1.0 / 4.0, amplitude: 1.41, phaseDegrees: 45.0, expectedDBTP: 3.0),
    ]

    @Test(
        "Tech 3341 true-peak sine cases 15-19 read within +0.2/-0.4 dB",
        arguments: [44_100.0, 48_000.0], [1, 2]
    )
    func sineCasesConform(sampleRate: Double, channelCount: Int) {
        for testCase in Self.sineCases {
            let buffer = Self.taperedSine(
                frequency: testCase.frequencyRatio * sampleRate,
                amplitude: testCase.amplitude,
                phaseDegrees: testCase.phaseDegrees,
                sampleRate: sampleRate,
                duration: 0.5,
                channelCount: channelCount
            )
            let offline = VoiceBoostTruePeakAnalyzer.truePeakDBTP(
                buffer,
                channelCount: channelCount,
                sampleRate: sampleRate
            )
            #expect(
                offline >= testCase.expectedDBTP - 0.4 && offline <= testCase.expectedDBTP + 0.2,
                "case \(testCase.name) offline read \(offline) at \(sampleRate) Hz"
            )
        }
    }

    @Test(
        "Runtime streaming meter matches the offline analyzer on the sine cases",
        arguments: [44_100.0, 48_000.0]
    )
    func runtimeMeterConformsAndAgreesWithOffline(sampleRate: Double) {
        for testCase in Self.sineCases {
            let channelCount = 2
            var buffer = Self.taperedSine(
                frequency: testCase.frequencyRatio * sampleRate,
                amplitude: testCase.amplitude,
                phaseDegrees: testCase.phaseDegrees,
                sampleRate: sampleRate,
                duration: 0.5,
                channelCount: channelCount
            )
            let offline = VoiceBoostTruePeakAnalyzer.truePeakDBTP(
                buffer,
                channelCount: channelCount,
                sampleRate: sampleRate
            )

            // A disabled processor passes the signal through (delayed), so
            // the output meter measures the fixture itself across real block
            // boundaries - the streaming path the limiter detector shares.
            let processor = VoiceBoostProcessor(
                sampleRate: sampleRate,
                channelCount: channelCount,
                configuration: VoiceBoostConfiguration(isEnabled: false)
            )
            var runtimeReading = -Double.infinity
            let blockFrames = 1_024
            let totalFrames = buffer.count / channelCount
            var offsetFrames = 0
            while offsetFrames < totalFrames {
                let frameCount = min(blockFrames, totalFrames - offsetFrames)
                buffer.withUnsafeMutableBufferPointer { pointer in
                    let block = UnsafeMutableBufferPointer(
                        start: pointer.baseAddress! + offsetFrames * channelCount,
                        count: frameCount * channelCount
                    )
                    processor.processInterleavedFloat32(block, frameCount: frameCount)
                }
                if let blockPeak = processor.metrics.outputTruePeakDBTP {
                    runtimeReading = max(runtimeReading, blockPeak)
                }
                offsetFrames += frameCount
            }

            #expect(
                runtimeReading >= testCase.expectedDBTP - 0.4
                    && runtimeReading <= testCase.expectedDBTP + 0.2,
                "case \(testCase.name) runtime read \(runtimeReading) at \(sampleRate) Hz"
            )
            #expect(abs(runtimeReading - offline) <= 0.05)
        }
    }

    @Test(
        "Tech 3341 downsampled-burst cases 20-23 read 0 dBTP within +0.2/-0.4 dB",
        arguments: [44_100.0, 48_000.0]
    )
    func downsampledBurstCasesConform(sampleRate: Double) {
        for offset in 0...3 {
            let buffer = Self.downsampledBurstFixture(
                sampleRate: sampleRate,
                downsampleOffset: offset,
                channelCount: 2
            )
            let reading = VoiceBoostTruePeakAnalyzer.truePeakDBTP(
                buffer,
                channelCount: 2,
                sampleRate: sampleRate
            )
            #expect(
                reading >= -0.4 && reading <= 0.2,
                "case \(20 + offset) read \(reading) at \(sampleRate) Hz"
            )
        }
    }

    /// Sine with the table's 10 ms raised-cosine fade-in/out.
    private static func taperedSine(
        frequency: Double,
        amplitude: Double,
        phaseDegrees: Double,
        sampleRate: Double,
        duration: Double,
        channelCount: Int
    ) -> [Float] {
        let frames = Int(sampleRate * duration)
        let fadeFrames = Int(0.010 * sampleRate)
        let phase = phaseDegrees * .pi / 180
        var buffer = [Float](repeating: 0, count: frames * channelCount)
        for frame in 0..<frames {
            var envelope = 1.0
            if frame < fadeFrames {
                envelope = 0.5 - 0.5 * cos(.pi * Double(frame) / Double(fadeFrames))
            } else if frame > frames - 1 - fadeFrames {
                envelope = 0.5 - 0.5 * cos(.pi * Double(frames - 1 - frame) / Double(fadeFrames))
            }
            let sample = Float(
                envelope * amplitude * sin(2 * .pi * frequency * Double(frame) / sampleRate + phase)
            )
            for channel in 0..<channelCount {
                buffer[frame * channelCount + channel] = sample
            }
        }
        return buffer
    }

    /// Cases 20-23: an fs/6 sine at 0.5 containing one phase-continuous
    /// period of an fs/4 sine at 1.0, synthesized at 4*fs, anti-alias
    /// lowpass filtered, and downsampled to fs with the given sample offset
    /// at the 4*fs rate.
    private static func downsampledBurstFixture(
        sampleRate: Double,
        downsampleOffset: Int,
        channelCount: Int
    ) -> [Float] {
        let factor = 4
        let hiCount = Int(4 * sampleRate * 0.25)
        // At 4*fs the fs/6 tone advances 2π/24 per sample and the fs/4 tone
        // 2π/16; the burst starts on an exact zero-phase sample of the base
        // tone and spans one full period, so phase is continuous throughout.
        let baseIncrement = 2 * Double.pi / 24
        let burstIncrement = 2 * Double.pi / 16
        let burstStart = (hiCount / 2 / 24) * 24
        let burstEnd = burstStart + 16

        var hi = [Double](repeating: 0, count: hiCount)
        var phase = 0.0
        for index in 0..<hiCount {
            let inBurst = index >= burstStart && index < burstEnd
            hi[index] = (inBurst ? 1.0 : 0.5) * sin(phase)
            phase += inBurst ? burstIncrement : baseIncrement
        }

        // Blackman-windowed-sinc anti-alias lowpass at 0.45*fs: flat at the
        // burst's fs/4, strongly attenuated by the fs/2 folding edge.
        let tapCount = 257
        let center = (tapCount - 1) / 2
        let cutoff = 0.45 / Double(factor)
        var taps = [Double](repeating: 0, count: tapCount)
        var tapSum = 0.0
        for index in 0..<tapCount {
            let offsetFromCenter = Double(index - center)
            let sinc = offsetFromCenter == 0
                ? 2 * cutoff
                : sin(2 * .pi * cutoff * offsetFromCenter) / (.pi * offsetFromCenter)
            let window = 0.42
                - 0.5 * cos(2 * .pi * Double(index) / Double(tapCount - 1))
                + 0.08 * cos(4 * .pi * Double(index) / Double(tapCount - 1))
            taps[index] = sinc * window
            tapSum += taps[index]
        }
        for index in 0..<tapCount {
            taps[index] /= tapSum
        }

        let outFrames = (hiCount - tapCount) / factor
        let fadeFrames = Int(0.010 * sampleRate)
        var buffer = [Float](repeating: 0, count: outFrames * channelCount)
        for frame in 0..<outFrames {
            let hiIndex = frame * factor + downsampleOffset
            var filtered = 0.0
            for tap in 0..<tapCount {
                filtered += taps[tap] * hi[hiIndex + tap]
            }
            var envelope = 1.0
            if frame < fadeFrames {
                envelope = 0.5 - 0.5 * cos(.pi * Double(frame) / Double(fadeFrames))
            } else if frame > outFrames - 1 - fadeFrames {
                envelope = 0.5 - 0.5 * cos(.pi * Double(outFrames - 1 - frame) / Double(fadeFrames))
            }
            let sample = Float(envelope * filtered)
            for channel in 0..<channelCount {
                buffer[frame * channelCount + channel] = sample
            }
        }
        return buffer
    }
}
