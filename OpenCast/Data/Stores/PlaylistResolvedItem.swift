/// A playlist item paired with the library's current snapshot of its
/// episode. A nil snapshot means the episode no longer resolves (for example
/// its show was unsubscribed) and the row renders from the item's fallbacks.
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
