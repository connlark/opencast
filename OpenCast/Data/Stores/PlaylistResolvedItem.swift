/// A nil snapshot means the episode no longer resolves, for example after its show is
/// unsubscribed.
nonisolated struct PlaylistResolvedItem: Identifiable, Equatable, Sendable {
    let item: PlaylistItem
    let snapshot: EpisodeListItemSnapshot?

    var id: String {
        item.itemID
    }

    var isResolved: Bool {
        snapshot != nil
    }
}
