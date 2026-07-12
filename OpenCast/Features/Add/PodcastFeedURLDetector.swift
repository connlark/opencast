import Foundation

enum PodcastFeedURLDetector {
    nonisolated static func feedURLString(from rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedValue),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host?.isEmpty == false
        else {
            return nil
        }

        return trimmedValue
    }
}
