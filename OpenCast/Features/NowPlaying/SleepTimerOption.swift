import Foundation

struct SleepTimerOption: Identifiable {
    /// The sleep durations OpenCast offers: the phone's list and the order the
    /// car's button cycles through.
    static let canonical: [SleepTimerOption] = [
        SleepTimerOption(title: "Off", duration: nil),
        SleepTimerOption(title: "15 Minutes", duration: 15 * 60),
        SleepTimerOption(title: "30 Minutes", duration: 30 * 60),
        SleepTimerOption(title: "45 Minutes", duration: 45 * 60),
        SleepTimerOption(title: "1 Hour", duration: 60 * 60)
    ]

    let title: String
    let duration: TimeInterval?

    var id: String {
        title
    }
}
