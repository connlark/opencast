/// Besides the fetches and deletes that regroup directly, the Notes library
/// regroups on a new search or sort, and when the library's episodes or
/// downloads change which notes resolve.
struct EpisodeNotesLibraryGroupingKey: Hashable {
    let query: String
    let sortOrder: EpisodeNotesLibrarySortOrder
    let episodesRevision: Int
    let downloadsRevision: Int
}
