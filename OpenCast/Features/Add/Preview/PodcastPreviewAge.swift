import Foundation

enum PodcastPreviewAge {
    case today
    case yesterday
    case days(Int)
    case weeks(Int)
    case month(Date)

    init(of date: Date) {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: .now)
        ).day ?? 0
        self = switch days {
        case ..<1: .today
        case 1: .yesterday
        case 2..<14: .days(days)
        case 14..<60: .weeks(days / 7)
        default: .month(date)
        }
    }

    var episodeText: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .days(let days): "\(days) days ago"
        case .weeks(let weeks): "\(weeks) weeks ago"
        case .month(let date): date.formatted(.dateTime.month(.wide).year())
        }
    }

    var newestText: String {
        switch self {
        case .today: "Newest today"
        case .yesterday: "Newest yesterday"
        default: "Newest \(episodeText)"
        }
    }
}
