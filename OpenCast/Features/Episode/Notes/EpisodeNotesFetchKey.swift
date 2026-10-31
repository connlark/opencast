/// The `.task(id:)` key of every view that fetches one episode's notes: a new
/// episode, or a change to that episode's notes (`EpisodeNotesChangeTracker`),
/// re-fetches. Nothing else does, so a listener without notes pays one empty
/// fetch per episode rather than a live query re-run on every save.
struct EpisodeNotesFetchKey: Hashable {
    let episodeID: String
    let revision: Int
}
