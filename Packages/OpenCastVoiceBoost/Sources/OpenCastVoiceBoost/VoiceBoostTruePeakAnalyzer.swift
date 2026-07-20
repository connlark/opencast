import Foundation
import OpenCastVoiceBoostC

/// Offline true-peak measurement per ITU-R BS.1770-4/5 Annex 2, backed by the
/// same C polyphase-FIR kernel that drives the runtime limiter detector and
/// output true-peak meter: offline verification measures exactly what the
/// processor enforces. Oversampling is 4x below 96 kHz and 2x at or above.
public enum VoiceBoostTruePeakAnalyzer {
    public static func samplePeakDBFS(_ buffer: [Float]) -> Double {
        VoiceBoostLevel.decibels(amplitude: buffer.reduce(0.0) { partialResult, sample in
            max(partialResult, abs(Double(sample)))
        })
    }

    public static func truePeakDBTP(
        _ buffer: [Float],
        channelCount: Int,
        sampleRate: Double = 48_000
    ) -> Double {
        VoiceBoostLevel.decibels(
            amplitude: truePeakAmplitude(buffer, channelCount: channelCount, sampleRate: sampleRate)
        )
    }

    public static func truePeakAmplitude(
        _ buffer: [Float],
        channelCount: Int,
        sampleRate: Double = 48_000
    ) -> Double {
        precondition(channelCount > 0)
        precondition(buffer.count.isMultiple(of: channelCount))
        guard !buffer.isEmpty else {
            return 0
        }

        return buffer.withUnsafeBufferPointer { pointer in
            OCVBTruePeakAmplitudeInterleavedFloat32(
                pointer.baseAddress,
                Int32(buffer.count / channelCount),
                Int32(channelCount),
                sampleRate
            )
        }
    }
}
