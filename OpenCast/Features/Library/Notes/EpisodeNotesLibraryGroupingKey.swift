struct EpisodeNotesLibraryGroupingKey: Hashable {
    let query: String
    let sortOrder: EpisodeNotesLibrarySortOrder
    let episodesRevision: Int
    let downloadsRevision: Int
}
