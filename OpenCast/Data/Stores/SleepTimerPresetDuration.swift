import Foundation

/// A duration the listener can put in one of the sleep timer's six preset
/// slots.
enum SleepTimerPresetDuration: Int, CaseIterable, Identifiable, Comparable, Codable {
    case five = 5
    case ten = 10
    case fifteen = 15
    case twenty = 20
    case thirty = 30
    case fortyFive = 45
    case sixty = 60
    case ninety = 90
    case oneHundredTwenty = 120

    static let defaults: [SleepTimerPresetDuration] = [.five, .ten, .fifteen, .thirty, .fortyFive, .sixty]

    var id: Int {
        rawValue
    }

    var minutes: Int {
        rawValue
    }

    var seconds: TimeInterval {
        TimeInterval(minutes * 60)
    }

    var title: String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        let hoursTitle = hours == 1 ? "1 Hour" : "\(hours) Hours"
        return switch (hours, remainingMinutes) {
        case (0, _):
            "\(remainingMinutes) Minutes"
        case (_, 0):
            hoursTitle
        default:
            "\(hoursTitle) \(remainingMinutes) Minutes"
        }
    }

    static func < (lhs: SleepTimerPresetDuration, rhs: SleepTimerPresetDuration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
