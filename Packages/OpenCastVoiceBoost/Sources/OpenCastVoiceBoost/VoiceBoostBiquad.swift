import Foundation

struct VoiceBoostBiquad {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
    var z1: Double = 0
    var z2: Double = 0

    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    static func bs1770PreFilter(sampleRate: Double) -> VoiceBoostBiquad {
        if abs(sampleRate - 44_100) < 1 {
            return VoiceBoostBiquad(
                b0: 1.530841230050347,
                b1: -2.650979995154729,
                b2: 1.169079079921906,
                a1: -1.663655113256020,
                a2: 0.712595428073225
            )
        }

        return VoiceBoostBiquad(
            b0: 1.53512485958697,
            b1: -2.69169618940638,
            b2: 1.19839281085285,
            a1: -1.69065929318241,
            a2: 0.73248077421585
        )
    }

    static func bs1770RLBFilter(sampleRate: Double) -> VoiceBoostBiquad {
        if abs(sampleRate - 44_100) < 1 {
            return VoiceBoostBiquad(
                b0: 1,
                b1: -2,
                b2: 1,
                a1: -1.989169673629796,
                a2: 0.989199035787039
            )
        }

        return VoiceBoostBiquad(
            b0: 1,
            b1: -2,
            b2: 1,
            a1: -1.99004745483398,
            a2: 0.99007225036621
        )
    }
}
