import Foundation

nonisolated enum PodcastPlaybackDurationText {
    static func parse(_ text: String) -> TimeInterval? {
        let components = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count) else {
            return nil
        }

        var total: TimeInterval = 0
        for (index, component) in components.enumerated() {
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = TimeInterval(component),
                  value.isFinite,
                  value >= 0,
                  (index == 0 || value < 60)
            else {
                return nil
            }
            total = total * 60 + value
            guard total.isFinite else {
                return nil
            }
        }
        return total
    }

    static func format(_ seconds: TimeInterval) -> String {
        let seconds = PodcastPlaybackSkipSettings.sanitized(seconds).rounded()
        return seconds.formattedPlaybackDuration(
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
