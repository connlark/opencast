import Foundation

enum EpisodeNotesLibraryGrouping {
    private typealias Section = (group: EpisodeNotesLibraryGroup, hasShowTitle: Bool, hasTitle: Bool)

    static func groups(
        from notes: [EpisodeNoteRecord],
        resolve: (String) -> EpisodeListItemSnapshot?,
        matching query: String,
        sortedBy order: EpisodeNotesLibrarySortOrder
    ) -> [EpisodeNotesLibraryGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Dictionary(grouping: notes, by: \.episodeID)
            .compactMap { episodeID, episodeNotes in
                section(episodeID: episodeID, notes: episodeNotes, episode: resolve(episodeID), query: query)
            }
            .sorted { precedes($0, $1, by: order) }
            .map(\.group)
    }

    private static func section(
        episodeID: String,
        notes: [EpisodeNoteRecord],
        episode: EpisodeListItemSnapshot?,
        query: String
    ) -> Section? {
        // The most recently touched note's details win: an edit refreshes them.
        let byActivity = notes.sorted { activity(of: $0) > activity(of: $1) }
        let showTitle = detail(byActivity.map { $0.podcastTitle }, fallback: episode?.podcastTitle)
        let episodeTitle = detail(byActivity.map { $0.episodeTitle }, fallback: episode?.title)
        let kept: [EpisodeNoteRecord]
        if query.isEmpty || [showTitle, episodeTitle].contains(where: { $0?.localizedStandardContains(query) == true }) {
            kept = notes
        } else {
            kept = notes.filter { $0.text.localizedStandardContains(query) }
        }
        guard !kept.isEmpty else { return nil }
        let group = EpisodeNotesLibraryGroup(
            episodeID: episodeID,
            podcastID: detail(byActivity.map { $0.podcastID }, fallback: episode?.podcastID) ?? "",
            podcastTitle: showTitle ?? "Unknown Show",
            episodeTitle: episodeTitle ?? "Unknown Episode",
            artworkURL: detail(byActivity.map(\.artworkURL), fallback: episode?.artworkURL),
            isResolved: episode != nil,
            publishedAt: episode?.publishedAt,
            notes: timelineOrdered(kept),
            latestActivity: byActivity.first.map(activity(of:)) ?? .distantPast
        )
        return (group, showTitle != nil, showTitle != nil || episodeTitle != nil)
    }

    private static func timelineOrdered(_ notes: [EpisodeNoteRecord]) -> [EpisodeNoteRecord] {
        let ordered = notes.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.noteID < rhs.noteID
        }
        return ordered.filter(\.isEpisodeWide) + ordered.filter { !$0.isEpisodeWide }
    }

    private static func precedes(_ lhs: Section, _ rhs: Section, by order: EpisodeNotesLibrarySortOrder) -> Bool {
        let (left, right) = (lhs.group, rhs.group)
        switch order {
        case .recent:
            if left.latestActivity != right.latestActivity {
                return left.latestActivity > right.latestActivity
            }
        case .show:
            if lhs.hasShowTitle != rhs.hasShowTitle {
                return lhs.hasShowTitle
            }
            if lhs.hasTitle != rhs.hasTitle {
                return lhs.hasTitle
            }
            guard lhs.hasTitle else { break }
            let showOrder = left.podcastTitle.localizedStandardCompare(right.podcastTitle)
            if showOrder != .orderedSame {
                return showOrder == .orderedAscending
            }
            switch (left.publishedAt, right.publishedAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                break
            }
            let titleOrder = left.episodeTitle.localizedStandardCompare(right.episodeTitle)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
        }
        return left.episodeID < right.episodeID
    }

    private static func activity(of note: EpisodeNoteRecord) -> Date {
        note.updatedAt ?? note.createdAt
    }

    private static func detail(_ stored: [String?], fallback: String?) -> String? {
        (stored + [fallback]).lazy.compactMap { $0 }.first { !$0.isEmpty }
    }
}
