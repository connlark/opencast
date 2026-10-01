import Foundation

/// A smart playlist's saved rule, stored as JSON in `PlaylistRecord.ruleJSON`.
/// Clauses combine with AND and are evaluated over the subscribed library.
/// Every optional defaults to nil and an absent key decodes to that nil, so
/// only `.default` carries a limit.
nonisolated struct PlaylistRule: Codable, Hashable, Sendable {
    static let currentVersion = 1
    static let statusOptions: [PodcastEpisodeFilter] = [.all, .unplayed, .inProgress, .played]
    static let agePresets: [Int?] = [nil, 7, 14, 30, 90, 365]
    static let limitPresets: [Int?] = [10, 25, 50, 100, nil]
    /// Unplayed, all shows, newest first, 25 episodes.
    static let `default` = PlaylistRule(limit: 25)

    var version = PlaylistRule.currentVersion
    /// Canonical feed URLs; nil means every subscribed show and is never
    /// stored as an empty list.
    var podcastIDs: [String]?
    /// Never `.downloaded`: normalization moves it to `downloadedOnly`.
    var status: PodcastEpisodeFilter = .unplayed
    var downloadedOnly = false
    /// Inclusive lower bound.
    var minimumMinutes: Int?
    /// Exclusive upper bound.
    var maximumMinutes: Int?
    var maximumAgeDays: Int?
    var sortOrder: PodcastEpisodeSortOrder = .newestFirst
    /// Nil means No Limit.
    var limit: Int?

    private enum CodingKeys: String, CodingKey {
        case version
        case podcastIDs
        case status
        case downloadedOnly
        case minimumMinutes
        case maximumMinutes
        case maximumAgeDays
        case sortOrder
        case limit
    }
}

// The decoder lives in an extension so the primary declaration keeps the
// memberwise initializer that `.default`, the rule chips and the tests use.
nonisolated extension PlaylistRule {
    /// `version` is required and must be 1; every other key falls back to
    /// its property default, so `{"version":1}` stays readable.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported playlist rule version \(version)."
            )
        }

        self.init(
            version: version,
            podcastIDs: try container.decodeIfPresent([String].self, forKey: .podcastIDs),
            status: try container.decodeIfPresent(PodcastEpisodeFilter.self, forKey: .status) ?? .unplayed,
            downloadedOnly: try container.decodeIfPresent(Bool.self, forKey: .downloadedOnly) ?? false,
            minimumMinutes: try container.decodeIfPresent(Int.self, forKey: .minimumMinutes),
            maximumMinutes: try container.decodeIfPresent(Int.self, forKey: .maximumMinutes),
            maximumAgeDays: try container.decodeIfPresent(Int.self, forKey: .maximumAgeDays),
            sortOrder: try container.decodeIfPresent(PodcastEpisodeSortOrder.self, forKey: .sortOrder) ?? .newestFirst,
            limit: try container.decodeIfPresent(Int.self, forKey: .limit)
        )
    }

    /// Nil for a missing, malformed or newer-version rule; never throws.
    static func decode(_ json: String?) -> PlaylistRule? {
        guard let json else {
            return nil
        }
        return (try? JSONDecoder().decode(PlaylistRule.self, from: Data(json.utf8)))?.normalized()
    }

    /// Sorted keys and unescaped slashes: the string is the evaluation memo
    /// key and the synced payload, so equal rules must encode identically.
    func encodedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(self)
            return String(decoding: data, as: UTF8.self)
        } catch {
            fatalError("A playlist rule holds only strings, integers and enums and cannot fail to encode: \(error)")
        }
    }

    /// The canonical form: show IDs deduplicated and sorted so toggle order
    /// never changes the stored rule, out-of-range numbers dropped, and the
    /// Downloaded filter moved to its own clause.
    func normalized() -> PlaylistRule {
        var rule = self
        if let podcastIDs {
            let uniqueIDs = Set(podcastIDs).sorted()
            rule.podcastIDs = uniqueIDs.isEmpty ? nil : uniqueIDs
        }
        if let limit, limit <= 0 {
            rule.limit = nil
        }
        if let minimumMinutes, minimumMinutes < 0 {
            rule.minimumMinutes = nil
        }
        if let maximumMinutes, maximumMinutes < 0 {
            rule.maximumMinutes = nil
        }
        if let maximumAgeDays, maximumAgeDays < 0 {
            rule.maximumAgeDays = nil
        }
        if status == .downloaded {
            rule.status = .all
            rule.downloadedOnly = true
        }
        return rule
    }

    /// The normalized rule with every listed show that `isMoved` matches
    /// replaced by `newPodcastID`, for a subscription that moved to a new
    /// feed URL; nil when the rule lists none of them.
    func replacingPodcastIDs(
        where isMoved: (String) -> Bool,
        with newPodcastID: String
    ) -> PlaylistRule? {
        guard let podcastIDs, podcastIDs.contains(where: isMoved) else {
            return nil
        }
        var rule = self
        rule.podcastIDs = podcastIDs.map { isMoved($0) ? newPodcastID : $0 }
        return rule.normalized()
    }

    var readsProgress: Bool {
        status != .all
    }

    // MARK: - Titles

    var episodesTitle: String {
        guard downloadedOnly else {
            return status.title
        }
        return status == .all ? "Downloaded" : "\(status.title), Downloaded"
    }

    var episodesSystemImage: String {
        downloadedOnly && status == .all ? "arrow.down.circle" : status.systemImage
    }

    /// Counts only the listed shows that are still subscribed.
    func showsTitle(subscribedPodcastIDs: Set<String>) -> String {
        guard let podcastIDs else {
            return "All Shows"
        }
        let count = podcastIDs.count(where: { subscribedPodcastIDs.contains($0) })
        guard count > 0 else {
            return "No Shows"
        }
        return String(AttributedString(localized: "^[\(count) Show](inflect: true)").characters)
    }

    var sortTitle: String {
        sortOrder.title
    }

    var lengthTitle: String {
        Self.lengthTitle(minimumMinutes: minimumMinutes, maximumMinutes: maximumMinutes)
    }

    var lengthAccessibilityTitle: String {
        Self.lengthAccessibilityTitle(minimumMinutes: minimumMinutes, maximumMinutes: maximumMinutes)
    }

    var ageTitle: String {
        Self.ageTitle(maximumAgeDays: maximumAgeDays)
    }

    var limitTitle: String {
        Self.limitTitle(limit: limit)
    }

    /// "Any Length", "Under 45 min", "Over 1 hr", "15–45 min".
    static func lengthTitle(minimumMinutes: Int?, maximumMinutes: Int?) -> String {
        switch (minimumMinutes, maximumMinutes) {
        case (nil, nil):
            "Any Length"
        case (nil, let maximum?):
            "Under \(shortMinutes(maximum))"
        case (let minimum?, nil):
            "Over \(shortMinutes(minimum))"
        case (let minimum?, let maximum?):
            minimum < 60 && maximum < 60
                ? "\(minimum)–\(maximum) min"
                : "\(shortMinutes(minimum))–\(shortMinutes(maximum))"
        }
    }

    /// "Any Length", "Under 45 minutes", "Over 1 hour", "15 to 45 minutes".
    static func lengthAccessibilityTitle(minimumMinutes: Int?, maximumMinutes: Int?) -> String {
        switch (minimumMinutes, maximumMinutes) {
        case (nil, nil):
            "Any Length"
        case (nil, let maximum?):
            "Under \(spokenMinutes(maximum))"
        case (let minimum?, nil):
            "Over \(spokenMinutes(minimum))"
        case (let minimum?, let maximum?):
            minimum < 60 && maximum < 60
                ? "\(minimum) to \(maximum) minutes"
                : "\(spokenMinutes(minimum)) to \(spokenMinutes(maximum))"
        }
    }

    /// "Any Time", "Last 7 days", "Last Year".
    static func ageTitle(maximumAgeDays: Int?) -> String {
        guard let maximumAgeDays else {
            return "Any Time"
        }
        guard maximumAgeDays != 365 else {
            return "Last Year"
        }
        let days = String(AttributedString(localized: "^[\(maximumAgeDays) day](inflect: true)").characters)
        return "Last \(days)"
    }

    /// "No Limit", "25 episodes".
    static func limitTitle(limit: Int?) -> String {
        guard let limit else {
            return "No Limit"
        }
        return String(AttributedString(localized: "^[\(limit) episode](inflect: true)").characters)
    }

    private static func shortMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 {
            return "\(minutes) min"
        }
        if remainder == 0 {
            return "\(hours) hr"
        }
        return "\(hours) hr \(remainder) min"
    }

    private static func spokenMinutes(_ minutes: Int) -> String {
        PlaylistDurationFormat.spoken(TimeInterval(minutes) * 60)
    }
}
