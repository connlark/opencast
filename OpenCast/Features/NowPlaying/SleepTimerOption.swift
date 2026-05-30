import Foundation

struct SleepTimerOption: Identifiable {
    let title: String
    let duration: TimeInterval?

    var id: String {
        title
    }
}
