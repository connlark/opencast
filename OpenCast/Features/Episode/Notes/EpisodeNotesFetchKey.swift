/// Only a new episode or a change to its notes re-fetches, so a listener without notes pays one
/// empty fetch per episode, not a live query re-run on every save.
struct EpisodeNotesFetchKey: Hashable {
    let episodeID: String
    let revision: Int
}
