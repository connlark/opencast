import Foundation

/// The eight fields a shared episode's web page needs, sanitised to the
/// version `1` wire rules the ShareWorker decodes (`Server/ShareWorker`).
/// Nothing about the sharer. The web decoder rejects a missing audio URL or
/// an empty title, so the failable initialisers return nil for those; the
/// encoder refuses the rare tuple too large for the decoder.
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

    /// The latest start the page honours: it treats a `?t=` past this as 0.
    public var maximumStartSeconds: Int {
        durationSeconds > 0 ? durationSeconds - 2 : Self.maximumStartWithoutDuration
    }

    static let maximumStartWithoutDuration = 86_400

    /// The tuple in wire order; the encoder joins it with `\n`.
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

    /// The trimmed string itself, never a re-encoded `URL.absoluteString`, so
    /// the recipient fetches exactly what the app plays. A newline or control
    /// character would split the tuple, so such a string is refused rather
    /// than repaired. The host and port checks cover what Foundation accepts
    /// but the worker's WHATWG parser rejects.
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

    /// Newlines and other control characters become single spaces: the web
    /// decoder strips control characters, so leaving any in would make a
    /// decoded payload differ from the one the app encoded. The cap counts
    /// UTF-16 units, the unit of the worker's own limits, and never splits a
    /// Character.
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
