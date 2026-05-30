import Foundation

enum PlaybackSkipIntervalOption: Int, CaseIterable, Identifiable {
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case sixty = 60

    static let defaultBackward = PlaybackSkipIntervalOption.thirty
    static let defaultForward = PlaybackSkipIntervalOption.fifteen

    var id: Int {
        rawValue
    }

    var seconds: TimeInterval {
        TimeInterval(rawValue)
    }

    var label: String {
        "\(rawValue)s"
    }

    var accessibilityLabel: String {
        "\(rawValue) seconds"
    }

    var backwardSystemImage: String {
        "gobackward.\(rawValue)"
    }

    var forwardSystemImage: String {
        "goforward.\(rawValue)"
    }

    static func option(for seconds: TimeInterval) -> PlaybackSkipIntervalOption {
        let roundedSeconds = Int(seconds.rounded())
        return Self(rawValue: roundedSeconds) ?? .defaultForward
    }
}
