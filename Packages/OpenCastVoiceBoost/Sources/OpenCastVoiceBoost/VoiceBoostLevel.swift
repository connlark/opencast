import Foundation

public enum VoiceBoostLevel {
    public static func linearAmplitude(decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    public static func decibels(amplitude: Double) -> Double {
        guard amplitude > 0, amplitude.isFinite else {
            return -.infinity
        }
        return 20 * log10(amplitude)
    }

    public static func loudness(meanSquare: Double) -> Double {
        guard meanSquare > 0, meanSquare.isFinite else {
            return -.infinity
        }
        return -0.691 + 10 * log10(meanSquare)
    }

    public static func meanSquare(loudnessLUFS: Double) -> Double {
        guard loudnessLUFS.isFinite else {
            return 0
        }
        return pow(10, (loudnessLUFS + 0.691) / 10)
    }
}
