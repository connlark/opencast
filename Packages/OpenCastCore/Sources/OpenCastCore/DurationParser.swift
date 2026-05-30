import Foundation

enum DurationParser {
    static func parse(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let seconds = TimeInterval(trimmed) {
            return seconds
        }

        let parts = trimmed.split(separator: ":").compactMap { TimeInterval($0) }
        guard parts.count == trimmed.split(separator: ":").count else {
            return nil
        }

        switch parts.count {
        case 3:
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2:
            return parts[0] * 60 + parts[1]
        case 1:
            return parts[0]
        default:
            return nil
        }
    }
}
