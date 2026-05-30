import Foundation

public enum URLCanonicalizer {
    public static func canonicalString(forRawString rawValue: String) -> String {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedValue),
              url.scheme != nil,
              url.host != nil
        else {
            return trimmedValue
        }

        return canonicalString(for: url)
    }

    public static func canonicalString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil

        if components.path == "/" {
            components.path = ""
        } else {
            components.path = components.path.trimmingTrailingSlashes()
        }

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems.sorted {
                if $0.name == $1.name {
                    return ($0.value ?? "") < ($1.value ?? "")
                }
                return $0.name < $1.name
            }
        }

        return components.url?.absoluteString ?? url.absoluteString
    }

    public static func podcastID(for feedURL: URL) -> PodcastID {
        PodcastID(rawValue: canonicalString(for: feedURL))
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var value = self
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
