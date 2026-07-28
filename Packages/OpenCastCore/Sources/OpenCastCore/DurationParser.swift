import Foundation

enum DurationParser {
    static func parse(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let seconds = TimeInterval(trimmed), seconds.isFinite, seconds >= 0 {
            return seconds
        }

        let rawParts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        let parts = rawParts.compactMap { TimeInterval($0) }
        guard
            parts.count == rawParts.count,
            parts.allSatisfy({ $0.isFinite && $0 >= 0 })
        else {
            return nil
        }
        guard (1...3).contains(parts.count) else {
            return nil
        }

        let duration = switch parts.count {
        case 3:
            parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2:
            parts[0] * 60 + parts[1]
        default:
            parts[0]
        }

        return duration.isFinite && duration >= 0 ? duration : nil
    }
}
