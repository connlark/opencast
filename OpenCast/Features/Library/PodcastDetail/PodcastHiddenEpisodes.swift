/// What a Group by Podcast visit keeps off the show's list, or the Inbox
/// off its own, as the caption over the list and the filtered-empty copy
/// name it.
nonisolated struct PodcastHiddenEpisodes: Equatable, Sendable {
    /// Archived episodes are off the list. Only set while the list has
    /// some, so the copy never names an empty archive.
    var archived = false
    /// Up Next and the playing episode are off the list.
    var queued = false
    /// Episodes not archived are off the list: a visit from the Inbox's
    /// archive view lists only the show's archived episodes. Only set while
    /// the show has some not archived, and never with `archived`.
    var unarchived = false

    /// The caption's text; nil while nothing is hidden.
    var caption: String? {
        if unarchived {
            return queued
                ? "Only archived episodes not playing or in Up Next are shown"
                : "Only archived episodes are shown"
        }
        return switch (archived, queued) {
        case (false, false):
            nil
        case (false, true):
            "Episodes playing or in Up Next are hidden"
        case (true, false):
            "Archived episodes are hidden"
        case (true, true):
            "Episodes archived, playing or in Up Next are hidden"
        }
    }

    var systemImage: String {
        archived || unarchived ? "archivebox" : "text.line.first.and.arrowtriangle.forward"
    }

    func filteredEmptyDescription(filter: PodcastEpisodeFilter) -> String {
        guard filter == .all else {
            return filteredEmptyDescription(hiddenUnder: filter) ?? filter.emptyStateDescription
        }
        if unarchived {
            return queued
                ? "No archived episodes to show. Episodes playing or in Up Next are hidden."
                : "No archived episodes to show."
        }
        return switch (archived, queued) {
        case (true, true):
            "Every episode in this podcast is archived, playing or in Up Next."
        case (true, false):
            "Every episode in this podcast is archived."
        case (false, true):
            "Every episode in this podcast is playing or in Up Next."
        case (false, false):
            filter.emptyStateDescription
        }
    }

    /// The filtered-empty copy under a filter other than All while
    /// something is hidden; nil while nothing is. What is hidden may be what
    /// emptied the list, so the filter's own claim ("every episode is marked
    /// as played") could be false: the copy says only that none are left to
    /// show, and what is hidden.
    func filteredEmptyDescription(hiddenUnder filter: PodcastEpisodeFilter) -> String? {
        guard let caption else {
            return nil
        }
        return "\(Self.noneToShow(under: filter)) \(caption)."
    }

    /// "No <noun> to show.", the nouns following `emptyStateTitle`.
    static func noneToShow(under filter: PodcastEpisodeFilter) -> String {
        switch filter {
        case .all:
            "No episodes to show."
        case .unplayed:
            "No unplayed episodes to show."
        case .inProgress:
            "No episodes in progress to show."
        case .played:
            "No played episodes to show."
        case .downloaded:
            "No downloaded episodes to show."
        }
    }
}
