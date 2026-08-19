struct FinishedPlaybackPresentation: Equatable, Identifiable {
    let episode: EpisodeListItemSnapshot

    var id: String {
        episode.id
    }
}
