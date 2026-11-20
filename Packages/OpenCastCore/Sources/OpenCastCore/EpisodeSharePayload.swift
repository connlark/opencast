import Foundation

public struct EpisodeSharePayload: Hashable, Sendable {
    public let audioURL: String
    public let title: String
    public let podcastTitle: String
    public let artworkURL: String
    public let feedURL: String
    public let guid: String
    public let durationSeconds: Int
    public let publishedUnix: Int

    static let maximumURLLength = 2048
    static let maximumTitleLength = 300
    static let maximumGUIDLength = 512
    // The decoder accepts at most 7 and 10 digits and reads anything longer as 0.
    static let maximumDurationSeconds = 9_999_999
    static let maximumPublishedUnix = 9_999_999_999

    public init?(
        audioURL: String?,
        title: String,
        podcastTitle: String,
        artworkURL: String?,
        feedURL: String?,
        guid: String?,
        duration: TimeInterval?,
        publishedAt: Date?
    ) {
        guard let audioURL = Self.webURL(audioURL) else {
            return nil
        }
        let title = Self.singleLine(title, limit: Self.maximumTitleLength)
        guard !title.isEmpty else {
            return nil
        }

        self.audioURL = audioURL
        self.title = title
        self.podcastTitle = Self.singleLine(podcastTitle, limit: Self.maximumTitleLength)
        self.artworkURL = Self.webURL(artworkURL) ?? ""
        self.feedURL = Self.webURL(feedURL) ?? ""
        self.guid = Self.singleLine(guid ?? "", limit: Self.maximumGUIDLength)
        self.durationSeconds = Self.wholeSeconds(duration)
        self.publishedUnix = Self.unixSeconds(publishedAt)
    }

    public init?(episode: Episode) {
        self.init(
            audioURL: episode.audioURL?.absoluteString,
            title: episode.title,
            podcastTitle: episode.podcastTitle,
            artworkURL: episode.artworkURL?.absoluteString,
            feedURL: episode.podcastID.rawValue,
            guid: episode.guid,
            duration: episode.duration,
            publishedAt: episode.publishedAt
        )
    }

    /// A day, not the feed's duration: dynamic ad insertion makes the served file longer or
    /// shorter than the RSS figure, so a start past the listed duration can be real.
    public var maximumStartSeconds: Int {
        Self.maximumStartWithoutDuration
    }

    static let maximumStartWithoutDuration = 86_400

    /// Wire order; any change needs a new token version.
    public var tupleFields: [String] {
        [
            audioURL,
            title,
            podcastTitle,
            artworkURL,
            feedURL,
            guid,
            String(durationSeconds),
            String(publishedUnix)
        ]
    }

    /// Returns the trimmed string, not `URL.absoluteString`, so the recipient fetches what the
    /// app plays. A control character would split the tuple, so it is refused. The host and port
    /// checks reject what Foundation accepts but the worker's WHATWG parser does not.
    private static func webURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.utf16.count <= maximumURLLength,
              !trimmed.contains(where: isLineBreakOrControl),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: true),
              !host.isEmpty,
              !host.contains("%"),
              isValidNumericHost(host),
              (url.port ?? 0) <= 65_535
        else {
            return nil
        }

        return trimmed
    }

    /// WHATWG parses any host whose last label is a number as IPv4 and fails
    /// it unless the whole host is an address. Accept only dotted quads there.
    private static func isValidNumericHost(_ host: String) -> Bool {
        var labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 1, labels.last?.isEmpty == true {
            labels.removeLast()
        }
        guard let last = labels.last, isNumericLabel(last) else {
            return true
        }
        return labels.count == 4 && labels.allSatisfy { label in
            label.allSatisfy { $0.isASCII && $0.isNumber } && (Int(label).map { $0 <= 255 } ?? false)
        }
    }

    private static func isNumericLabel(_ label: Substring) -> Bool {
        if label.lowercased().hasPrefix("0x") {
            return label.dropFirst(2).allSatisfy(\.isHexDigit)
        }
        return !label.isEmpty && label.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Control characters become spaces because the web decoder strips them. The cap counts
    /// UTF-16 units, as the worker's limits do, and never splits a Character.
    private static func singleLine(_ value: String, limit: Int) -> String {
        let flattened = String(value.map { isLineBreakOrControl($0) ? " " : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var capped = ""
        var units = 0
        for character in flattened {
            units += character.utf16.count
            guard units <= limit else {
                break
            }
            capped.append(character)
        }
        return capped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLineBreakOrControl(_ character: Character) -> Bool {
        character.isNewline || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func wholeSeconds(_ duration: TimeInterval?) -> Int {
        guard let duration, duration.isFinite, duration > 0 else {
            return 0
        }
        let rounded = duration.rounded()
        return rounded <= Double(maximumDurationSeconds) ? Int(rounded) : 0
    }

    private static func unixSeconds(_ date: Date?) -> Int {
        guard let seconds = date?.timeIntervalSince1970,
              seconds.isFinite,
              seconds >= 0,
              seconds <= Double(maximumPublishedUnix)
        else {
            return 0
        }
        return Int(seconds)
    }
}
