import Foundation

/// `M:SS` or `H:MM:SS`, not glued to digits or colons, and not a clock time (`8:39 pm`),
/// a fraction or an ISO date's time.
public enum ShowNotesTimestamp {
    /// Capture groups: hours (optional), minutes, seconds.
    public static let pattern = #"(?<![\d:T])(?:(\d{1,2}):)?([0-5]?\d):([0-5]\d)(?![\d:]|\.\d|\s*(?i:[ap]\.?m)\b)"#

    public static let regex = try! NSRegularExpression(pattern: pattern)

    public static func seconds(of match: NSTextCheckingResult, in text: String, groupOffset: Int = 0) -> Int? {
        // Checked before `groupOffset + index`, which would overflow for an offset near `Int.max`.
        guard (0..<match.numberOfRanges).contains(groupOffset) else {
            return nil
        }
        func component(_ index: Int) -> Int? {
            let group = groupOffset + index
            guard (0..<match.numberOfRanges).contains(group) else {
                return nil
            }
            return Range(match.range(at: group), in: text).flatMap { Int(text[$0]) }
        }
        guard let minutes = component(2), let seconds = component(3) else {
            return nil
        }
        return (component(1) ?? 0) * 3600 + minutes * 60 + seconds
    }
}
