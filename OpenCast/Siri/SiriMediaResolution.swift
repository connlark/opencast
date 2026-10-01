nonisolated enum SiriMediaResolution: Equatable, Sendable {
    case show(podcastID: String)
    case episode(episodeID: String)
    case playlist(playlistID: String)
    case resume
    case noMatch
}
