nonisolated enum SiriMediaResolution: Equatable, Sendable {
    case show(podcastID: String)
    case episode(episodeID: String)
    case resume
    case noMatch
}
